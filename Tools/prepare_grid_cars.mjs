// Convert the pinned Creative Commons source models to the driving scene layout.
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { compactPrimitive, join, prune, simplify, transformPrimitive, weld } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';

const [input, output, kind] = process.argv.slice(2);
const configs = {
    porsche: {
        sourceToCar: [1.039,0,0,0,0,0.904,0,0,0,0,0.9465,0,0,0.012656,-0.0407,1],
        wheelCentres: [[-0.716,0.349,1.335],[0.712,0.349,1.328],[-0.741,0.349,-1.251],[0.717,0.349,-1.242]],
        pivots: [0.75,0.328,1.22],
        steering: [0.373,0.802,0.542]
    },
    lotus: {
        sourceToCar: [-0.677,0,0,0,0,0.65,0,0,0,0,-0.654,0,0,0.00845,0.01864,1],
        wheelCentres: [[1.071,0.501,-1.729],[-1.071,0.501,-1.729],[1.071,0.501,1.786],[-1.071,0.501,1.786]],
        pivots: [0.725,0.334,1.15],
        steering: [-0.434,1.05,-0.615]
    },
    honda: {
        sourceToCar: [0,0,-0.01,0,0,0.01,0,0,0.01,0,0,0,0,0.1933,1.334275,1],
        wheelCentres: [[8.192,13.153,-71.9],[8.192,13.153,71.9],[258.663,13.153,-71.9],[258.663,13.153,71.9]],
        pivots: [0.719,0.325,1.252355],
        steering: [100.15,80.095,33.011]
    }
};
const config = configs[kind];
if (!config || !input || !output) throw new Error('Expected source.glb output.glb porsche|lotus|honda');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const document = await io.read(input);
if (kind === 'honda') {
    await MeshoptSimplifier.ready;
    await document.transform(weld(),simplify({simplifier:MeshoptSimplifier,ratio:0.10,error:0.008}));
}
const root = document.getRoot();
const sourceNodes = [...root.listNodes()];
const scene = document.createScene('Driving vehicle');
const groups = new Map();
const wheelNames = ['WheelFR','WheelFL','WheelRR','WheelRL'];

function transformPoint(point) {
    return [0,1,2].map(i => config.sourceToCar[i]*point[0]+config.sourceToCar[4+i]*point[1]+
        config.sourceToCar[8+i]*point[2]+config.sourceToCar[12+i]);
}
function translation([x,y,z]) { return [1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1]; }
function group(name) {
    if (!groups.has(name)) {
        const node = document.createNode(name);
        scene.addChild(node);
        groups.set(name,node);
    }
    return groups.get(name);
}
function add(parent,name,primitive) {
    group(parent).addChild(document.createNode(name).setMesh(document.createMesh(name).addPrimitive(primitive)));
}
function copy(source,indices=source.getIndices().getArray()) {
    const primitive = source.clone();
    for (const semantic of source.listSemantics()) {
        const attribute = source.getAttribute(semantic);
        primitive.setAttribute(semantic,attribute.clone().setArray(attribute.getArray().slice()));
    }
    primitive.setIndices(source.getIndices().clone().setArray(indices.slice()));
    return primitive;
}
function split(primitive,classify) {
    const positions = primitive.getAttribute('POSITION').getArray();
    const indices = primitive.getIndices().getArray();
    const partitions = new Map();
    for (let i=0;i<indices.length;i+=3) {
        const face = indices.subarray(i,i+3);
        const [a,b,c] = Array.from(face,index=>positions.subarray(3*index,3*index+3));
        const centre = [0,1,2].map(j=>(a[j]+b[j]+c[j])/3);
        const key = classify(centre,a,b,c,face);
        if (!partitions.has(key)) partitions.set(key,[]);
        partitions.get(key).push(...face);
    }
    return new Map([...partitions].map(([role,indices])=>[role,new Uint32Array(indices)]));
}
function splitConnected(primitive,[low,high]) {
    const positions=primitive.getAttribute('POSITION').getArray();
    const indices=primitive.getIndices().getArray();
    const parents=[];
    const positionKeys=new Map();
    const find = index => {
        while (index!==parents[index]) {
            parents[index]=parents[parents[index]];
            index=parents[index];
        }
        return index;
    };
    for (let i=0;i<positions.length;i+=3) {
        const key=positions.subarray(i,i+3).map(value=>Math.round(value*10_000)).join(',');
        const parent=positionKeys.get(key) ?? i/3;
        parents.push(parent);
        positionKeys.set(key,parent);
    }
    for (let i=0;i<indices.length;i+=3) {
        const parent=find(indices[i]);
        parents[find(indices[i+1])]=parent;
        parents[find(indices[i+2])]=parent;
    }
    const other=new Set();
    for (let i=0;i<parents.length;i++) {
        const point=positions.subarray(3*i,3*i+3);
        if (point.some((axis,j)=>axis<low[j] || axis>high[j])) other.add(find(i));
    }
    return split(primitive,(_centre,_a,_b,_c,face)=>other.has(find(face[0])) ? 'Body' : 'Steering');
}
function rearFacing(a,b,c,direction) {
    const u = b.map((v,i)=>v-a[i]), v = c.map((x,i)=>x-a[i]);
    const normal = [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]];
    return normal[direction] < -0.38*Math.hypot(...normal);
}
function classifyPorsche(name,material,primitive) {
    const wheel = p => (p[2]>0 ? 0 : 2)+(p[0]>0 ? 1 : 0);
    if (name === 'Object_10') return split(primitive,p=>wheelNames[wheel(p)]);
    if (name === 'Object_12') return split(primitive,p=>{
        const index=wheel(p), centre=config.wheelCentres[index];
        return Math.abs(p[0]-centre[0])<0.20 && Math.hypot(p[1]-centre[1],p[2]-centre[2])<0.329
            ? wheelNames[index] : 'Body';
    });
    if (name === 'Object_16') {
        return splitConnected(primitive,[[0.176,0.629,0.415],[0.57,0.975,0.670]]);
    }
    if (name === 'Object_24') return split(primitive,(_,a,b,c)=>rearFacing(a,b,c,2) ? 'Mirror' : 'Body');
    if (name === 'Object_4') return new Map([['Brake',primitive.getIndices().getArray()]]);
    return new Map([[material==='glass' ? 'Window' : 'Body',primitive.getIndices().getArray()]]);
}
function classifyLotus(name,parent,material,primitive) {
    const layers = {2:'WheelFL',16:'WheelFR',17:'WheelRL',18:'WheelRR'};
    const layer = Number(parent.match(/:Layer(\d+)$/)?.[1]);
    const role = layers[layer] ?? (layer===12 ? 'Steering' : material==='CAR.mirroir' ? 'Mirror' :
        material==='CAR.lamp-arr-rouge' ? 'Brake' :
        material==='CAR.verre' && [7,8,9].includes(layer) ? 'Window' : 'Body');
    return new Map([[role,primitive.getIndices().getArray()]]);
}
function classifyHonda(name,parent,material,primitive) {
    if (/^(Llanta|TaponLlanta|TornillosLlanta|Pneumatico|HondaLogosRuedas)/.test(parent)) {
        return split(primitive,p=>wheelNames[(p[0]>133.428 ? 2 : 0)+(p[2]>0 ? 1 : 0)]);
    }
    const role = (/Volante/.test(parent) && parent!=='BaseTraseraVolante') ? 'Steering' :
        material==='RetroScreens' ? 'Mirror' : name.startsWith('FarosTraserosCirculoDividido') ? 'Brake' :
        material==='Cristal' || material==='CristalTintado'
            ? 'Window' : 'Body';
    return new Map([[role,primitive.getIndices().getArray()]]);
}

const adaptedMaterials = new Map();
function adaptMaterial(original,role) {
    const name = role === 'Mirror' ? 'AuthoredMirrorGlass' : role === 'Brake' ? 'SourcedBrakeLamp' : 'CockpitWindow';
    if (!adaptedMaterials.has(original)) adaptedMaterials.set(original,new Map());
    const variants = adaptedMaterials.get(original);
    if (!variants.has(role)) variants.set(role,original.clone().setName(name));
    return variants.get(role);
}

for (const node of sourceNodes) {
    const name = node.getName();
    const parent = node.getParentNode()?.getName() ?? '';
    if (kind==='lotus' && (/^Object_(7[2-9]|80)$/.test(name) || /NANA|:Layer3$|^SOL01$/.test(parent) ||
        (parent.endsWith(':Layer6') && name.includes('CAR.verre')))) continue;
    for (const source of node.getMesh()?.listPrimitives() ?? []) {
        const staged = copy(source);
        transformPrimitive(staged,node.getWorldMatrix());
        const material = source.getMaterial()?.getName();
        const parts = kind==='porsche' ? classifyPorsche(name,material,staged) : kind==='lotus' ?
            classifyLotus(name,parent,material,staged) : classifyHonda(name,parent,material,staged);
        for (const [role,indices] of parts) {
            const part = copy(staged,indices);
            compactPrimitive(part);
            transformPrimitive(part,config.sourceToCar);
            if (role.startsWith('Wheel')) {
                const label = role.split('.')[0];
                const i = wheelNames.indexOf(label);
                const centre = transformPoint(config.wheelCentres[i]);
                const [track,radius,axle] = config.pivots;
                transformPrimitive(part,translation(centre.map(v=>-v)));
                group(label).setTranslation([(i%2===0 ? -1 : 1)*track,radius,(i<2 ? 1 : -1)*axle]);
                add(label,role.endsWith('.caliper') ? 'BrakeCaliperMesh' : name,part);
            } else if (role==='Steering') {
                const pivot=transformPoint(config.steering);
                transformPrimitive(part,translation(pivot.map(v=>-v)));
                group(role).setTranslation(pivot);
                add(role,'AuthoredSteeringWheel',part);
            } else {
                if (role!=='Body') part.setMaterial(adaptMaterial(part.getMaterial(),role));
                add('Body',name,part);
            }
        }
        staged.dispose();
    }
}
if (![...wheelNames,'Steering'].every(name=>groups.has(name))) throw new Error('Missing authored steering or wheel meshes');
root.setDefaultScene(scene);
for (const old of root.listScenes()) if (old!==scene) old.dispose();
for (const node of sourceNodes) node.dispose();
if (kind==='honda') {
    const separate = new Set(['AuthoredMirrorGlass','CockpitWindow']);
    await document.transform(join({filter:node=>node.getMesh()!==null &&
        !node.getMesh().listPrimitives().some(primitive=>separate.has(primitive.getMaterial()?.getName()))}));
}
await document.transform(prune());
await io.write(output,document);
