// Rebuild the pinned Mazda and BMW GLBs from their Creative Commons originals.
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { prune, transformPrimitive } from '@gltf-transform/functions';

const [source, destination, model] = process.argv.slice(2);
if (!['mazda', 'bmw'].includes(model)) throw new Error('Expected source.glb output.glb mazda|bmw');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const document = await io.read(source);
const root = document.getRoot();
const originals = [...root.listNodes()];
const scene = document.createScene('Driving vehicle');
const mazda = model === 'mazda';
const wheelbase = mazda ? 2.2597 : 2.5911;
const track = mazda ? 1.4066 : 1.4067;
const radius = mazda ? 0.3007 : 0.3116;

const center = mazda ? [160.831,44.831,95.18153] : [0,0.020,0.157];
const scale = mazda ? [track/100.57,radius/20.03,wheelbase/155.19651] : [track/1.557,radius/0.3665,wheelbase/3.10];
const steeringPivot = mazda ? [187.718,94.132,101.804] : [0.435,0.995,0.609];
const names = new Map();
const translate = (x,y,z) => [1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1];
const normalize = [scale[0],0,0,0,0,scale[1],0,0,0,0,scale[2],0,
                   -center[0]*scale[0],-center[1]*scale[1],-center[2]*scale[2],1];
const wheelPattern = mazda ? /^Circle\.00[2345]$/ : /^(tire_cap|Rays_TE37|Brakedisc_2|BrakeDisc_1|Bolts|Axle|wheel_rb|caliper_rb)(\.00[123])?$/;
const wheelCenters = mazda
    ? [[210.77296,64.86151,17.58327],[210.77296,64.86151,172.77979],
       [111.44981,64.86151,172.77979],[111.44981,64.86151,17.58327]]
    : [[0.779,0.374,-1.393],[-0.779,0.374,-1.393],
       [0.777,0.374,1.741],[-0.778,0.374,1.677]];

function group(name) {
    if (!names.has(name)) {
        const node = document.createNode(name);
        scene.addChild(node);
        names.set(name,node);
    }
    return names.get(name);
}

function copyPrimitive(original, triangles = original.getIndices().getArray()) {
    const copy = original.clone();
    const remap = new Map();
    const referenced = [];
    const IndexArray = triangles.length > 65_535 ? Uint32Array : Uint16Array;
    const indices = IndexArray.from(triangles, vertex => {
        if (!remap.has(vertex)) {
            remap.set(vertex,referenced.length);
            referenced.push(vertex);
        }
        return remap.get(vertex);
    });
    for (const semantic of original.listSemantics()) {
        const attribute = original.getAttribute(semantic);
        const array = attribute.getArray();
        const size = attribute.getElementSize();
        const selected = new array.constructor(referenced.length*size);
        for (const [offset, vertex] of referenced.entries()) {
            selected.set(array.subarray(vertex*size,vertex*size+size),offset*size);
        }
        copy.setAttribute(semantic,attribute.clone().setArray(selected));
    }
    copy.setIndices(original.getIndices().clone().setArray(indices));
    return copy;
}

function add(name, target, primitive) {
    const mesh = document.createMesh(name).addPrimitive(primitive);
    group(target).addChild(document.createNode(name).setMesh(mesh));
}

function splitTriangles(primitive, keyForTriangle) {
    const groups = new Map();
    const positions = primitive.getAttribute('POSITION').getArray();
    const indices = primitive.getIndices().getArray();
    for (let i=0; i<indices.length; i+=3) {
        const triangle = Array.from(indices.subarray(i,i+3));
        const points = triangle.map(v => Array.from(positions.subarray(3*v,3*v+3)));
        const center = [0,1,2].map(axis => points.reduce((sum,p) => sum+p[axis],0)/3);
        const key = keyForTriangle(center,points,triangle);
        if (!groups.has(key)) groups.set(key,[]);
        groups.get(key).push(...triangle);
    }
    return groups;
}

function normal(_points) {
    const [a,b,c] = _points;
    const [ux,uy,uz] = b.map((value,i)=>value-a[i]);
    const [vx,vy,vz] = c.map((value,i)=>value-a[i]);
    return [uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx];
}

function steeringVertices(primitive) {
    const positions = primitive.getAttribute('POSITION').getArray();
    const indices = primitive.getIndices().getArray();
    const parents = [];
    const positionKeys = new Map();
    const find = index => {
        while (index !== parents[index]) {
            parents[index] = parents[parents[index]];
            index = parents[index];
        }
        return index;
    };
    for (let i=0; i<positions.length; i+=3) {
        const key = positions.subarray(i,i+3).map(value=>Math.round(value*10_000)).join(',');
        const parent = positionKeys.get(key) ?? i/3;
        parents.push(parent);
        positionKeys.set(key,parent);
    }
    for (let i=0; i<indices.length; i+=3) {
        const parent = find(indices[i]);
        parents[find(indices[i+1])] = parent;
        parents[find(indices[i+2])] = parent;
    }
    const parts = new Map();
    for (let i=0; i<parents.length; i++) {
        const root = find(i);
        if (!parts.has(root)) parts.set(root,[]);
        parts.get(root).push(i);
    }
    const inside = mazda
        ? (x,y,z) => x>176.26 && x<199.18 && y>83.12 && y<105.14 && z>98.28 && z<105.33
        : (x,y,z) => x>0.25 && x<0.621 && y>0.82 && y<1.169 && z>0.530 && z<0.685;
    const steering = new Set();
    for (const part of parts.values()) {
        if (part.length>20 && part.every(i=>inside(...positions.subarray(3*i,3*i+3)))) {
            for (const i of part) steering.add(i);
        }
    }
    return steering;
}
const mirrorMaterial = document.createMaterial('AuthoredMirrorGlass')
    .setBaseColorFactor([0.28,0.30,0.32,1]).setMetallicFactor(0.8).setRoughnessFactor(0.17);
const mazdaBrakeLamp = root.listMaterials().find(material=>material.getName()==='Material.012')?.clone()
    .setName('SourcedBrakeLamp');

for (const node of originals) {
    const mesh = node.getMesh();
    const parent = node.getParentNode()?.getName() ?? '';
    if (!mesh || (!mazda && ['Plane','suspention'].includes(parent))) continue;
    const wheel = parent.match(wheelPattern);
    for (const original of mesh.listPrimitives()) {
        const name = node.getName();
        const material = original.getMaterial()?.getName() ?? '';
        const primitive = copyPrimitive(original);
        transformPrimitive(primitive,node.getWorldMatrix());
        if (wheel) {
            const index = mazda ? Number(parent.at(-1))-2 : Number(wheel[2]?.at(-1) ?? 0);
            const [x,y,z] = wheelCenters[index];
            const target = 'Wheel'+(z>center[2] ? 'F' : 'R')+(x>center[0] ? 'L' : 'R');
            transformPrimitive(primitive,translate(-x,-y,-z));
            if (!mazda && index >= 2) {
                // The source shows the front wheels turned ~14° on both sides.
                const angle = 0.25;
                const c = Math.cos(angle), s = Math.sin(angle);
                transformPrimitive(primitive,[c,0,-s,0,0,1,0,0,s,0,c,0,0,0,0,1]);
            }
            transformPrimitive(primitive,[scale[0],0,0,0,0,scale[1],0,0,0,0,scale[2],0,0,0,0,1]);
            group(target).setTranslation([(target.endsWith('L') ? 1 : -1)*track/2,radius,
                (target.startsWith('WheelF') ? 1 : -1)*wheelbase/2]);
            add(material === 'wheel_caliper' ? 'BrakeCaliperMesh' : name,target,primitive);
            continue;
        }
        if (name === (mazda ? 'Cube.001_Material.001_0' : 'interior_1')) {
            const steering = steeringVertices(primitive);
            const parts = splitTriangles(primitive,(p,points,indices) => {
                if (indices.every(i=>steering.has(i))) return 'Steering';
                if (!mazda) return 'Body';
                if (p[1]>99.65 && p[1]<105.5 && p[2]>98.72 && p[2]<101.80 && (p[0]>213.28 || p[0]<108.38)) {
                    const [nx,ny,nz] = normal(points);
                    if (Math.abs(nz)>0.62*Math.hypot(nx,ny,nz)) return p[0]>center[0] ? 'MirrorLeft' : 'MirrorRight';
                }
                if (Math.abs(p[0]-center[0])<8.55 && p[1]>114.60 && p[1]<118.54 && p[2]>100.42 && p[2]<100.99) {
                    const [nx,ny,nz] = normal(points);
                    if (nz < -0.95*Math.hypot(nx,ny,nz)) return 'MirrorCentre';
                }
                return 'Body';
            });
            if (!parts.has('Steering')) throw new Error('Steering binding is missing');
            for (const [target,indices] of parts) {
                const part = copyPrimitive(primitive,indices);
                if (target === 'Steering') {
                    transformPrimitive(part,translate(-steeringPivot[0],-steeringPivot[1],-steeringPivot[2]));
                    transformPrimitive(part,[scale[0],0,0,0,0,scale[1],0,0,0,0,scale[2],0,0,0,0,1]);
                    group(target).setTranslation(steeringPivot.map((v,axis)=>(v-center[axis])*scale[axis]));
                    add('AuthoredSteeringWheel',target,part);
                } else {
                    transformPrimitive(part,normalize);
                    if (target.startsWith('Mirror')) part.setMaterial(mirrorMaterial);
                    add(target === 'Body' ? name : target,'Body',part);
                }
            }
        } else if (mazda && material === 'Material.012') {
            const parts = splitTriangles(primitive,p => Math.abs(p[0]-center[0])<6.3 && p[1]>96.2 && p[2]<-31.8);
            for (const [brake,indices] of parts) {
                const part = copyPrimitive(primitive,indices);
                if (brake) part.setMaterial(mazdaBrakeLamp);
                transformPrimitive(part,normalize);
                add(brake ? 'AuthoredBrakeLamp' : name,'Body',part);
            }
        } else {
            transformPrimitive(primitive,normalize);
            add(name,'Body',primitive);
        }
    }
}
const materialNames = mazda
    ? {'Material.010':'window','Material.004':'window','Material.012':'MazdaLamps','Material.002':'AuthoredPaint'}
    : {body:'AuthoredPaint',glass_window:'window',glass_window_back:'window',emission_back:'SourcedBrakeLamp'};
for (const material of root.listMaterials()) {
    const name = materialNames[material.getName()];
    if (name) material.setName(name);
}
root.setDefaultScene(scene);
for (const old of root.listScenes()) if (old !== scene) old.dispose();
for (const node of originals) node.dispose();
await document.transform(prune());
await io.write(destination,document);
