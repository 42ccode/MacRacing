// Offline conversion of the two pinned carros GLBs. See Assets/Vehicles/README.md.
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dequantize, prune, transformPrimitive } from '@gltf-transform/functions';
import { MeshoptDecoder } from 'meshoptimizer';

const [source, destination, model] = process.argv.slice(2);
if (!['bmw', 'mazda'].includes(model)) throw new Error('Expected source.glb output.glb bmw|mazda');
await MeshoptDecoder.ready;
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'meshopt.decoder': MeshoptDecoder});
const document = await io.read(source);
await document.transform(dequantize());
const root = document.getRoot();
const originals = [...root.listNodes()];
const scene = document.createScene('Driving vehicle');
const isBMW = model === 'bmw';
const tire = isBMW ? 'BMW_E30_M3_TIRE' : 'Scene_-_Root.002';
const wheelCenters = new Map();
const tireKey = (x, z) => 'Wheel' + (z > 0 ? 'F' : 'R') + (x > 0 ? 'L' : 'R');
for (const node of originals) {
    if (!node.getMesh()?.listPrimitives().some(primitive => primitive.getMaterial()?.getName() === tire)) continue;
    const matrix = node.getWorldMatrix();
    wheelCenters.set(tireKey(matrix[12], matrix[14]), matrix);
}
if (wheelCenters.size !== 4) throw new Error('Four separate tire nodes are required');
const front = wheelCenters.get('WheelFL'), rear = wheelCenters.get('WheelRL');
const track = (Math.abs(front[12]) + Math.abs(rear[12]) + Math.abs(wheelCenters.get('WheelFR')[12]) + Math.abs(wheelCenters.get('WheelRR')[12])) / 2;
const wheelbase = front[14] - rear[14];
const middle = (front[14] + rear[14]) / 2;
const radius = Math.hypot(rear[8], rear[9], rear[10]);
const ground = front[13] - radius;
const groups = new Map();
const translation = (x,y,z) => [1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1];

function group(key) {
    if (!groups.has(key)) {
        const node = document.createNode(key);
        scene.addChild(node); groups.set(key, node);
    }
    return groups.get(key);
}

function copyPrimitive(original) {
    const copy = original.clone();
    for (const semantic of original.listSemantics()) {
        const attribute = original.getAttribute(semantic);
        copy.setAttribute(semantic, attribute.clone().setArray(attribute.getArray().slice()));
    }
    const indices = original.getIndices();
    if (indices) copy.setIndices(indices.clone().setArray(indices.getArray().slice()));
    return copy;
}

const byMaterial = isBMW
    ? ['BMW_E30_M3_RIM', tire, 'Brake_Disc', 'Brembo_Calipers', 'Logo_Plane']
    : ['RRpbrAluminumSemiPolish', tire, 'amdb11_brake.002', 'amdb11_misc_chrome.002', 'amdb11_misc.002', 'amdb11_badging.002', 'amdb11_caliper.002'];
for (const node of originals) {
    if (!node.getMesh()) continue;
    const parent = node.getParentNode()?.getName() ?? '';
    for (const original of node.getMesh().listPrimitives()) {
        const material = original.getMaterial()?.getName() ?? '';
        const primitive = copyPrimitive(original);
        transformPrimitive(primitive, node.getWorldMatrix());
        const vertices = primitive.getAttribute('POSITION').getArray();
        let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
        for (let index = 0; index < vertices.length; index += 3) {
            minX = Math.min(minX, vertices[index]); maxX = Math.max(maxX, vertices[index]);
            minZ = Math.min(minZ, vertices[index+2]); maxZ = Math.max(maxZ, vertices[index+2]);
        }
        let key = 'Body';
        let name = node.getName();
        const wheelPart = byMaterial.includes(material) &&
            (isBMW || material === tire || parent.startsWith('RLA_miata_wheel') || parent.startsWith('amdb11_brakedisc'));
        if (wheelPart) {
            key = tireKey((minX+maxX)/2, (minZ+maxZ)/2);
            const center = wheelCenters.get(key);
            transformPrimitive(primitive, translation(-center[12], -center[13], -center[14]));
            if (isBMW) {
                // Source front wheels are displayed at about 29° of steering.
                const angle = Math.atan2(center[2], center[0]);
                const c = Math.cos(angle), s = Math.sin(angle);
                transformPrimitive(primitive, [c,0,-s,0,0,1,0,0,s,0,c,0,0,0,0,1]);
            } else {
                // Remove the display camber before applying runtime steering and roll.
                const angle = -Math.atan2(Math.sign(center[0])*center[1], Math.abs(center[0]));
                const c = Math.cos(angle), s = Math.sin(angle);
                transformPrimitive(primitive, [c,s,0,0,-s,c,0,0,0,0,1,0,0,0,0,1]);
            }
            if (/caliper|Logo_Plane|badging/i.test(material)) name = 'BrakeCaliperMesh';
            group(key).setTranslation([(key.endsWith('L') ? 1 : -1)*track/2, radius, (key.startsWith('WheelF') ? 1 : -1)*wheelbase/2]);
        } else if (!isBMW && parent === 'RLA_miata_steeringwheel_a') {
            key = 'Steering';
            const pivot = [0.363,0.784,0.158];
            transformPrimitive(primitive, translation(-pivot[0],-pivot[1],-pivot[2]));
            group(key).setTranslation([pivot[0],pivot[1]-ground,pivot[2]-middle]);
        } else {
            transformPrimitive(primitive, translation(0,-ground,-middle));
        }
        const mesh = document.createMesh(name).addPrimitive(primitive);
        group(key).addChild(document.createNode(name).setMesh(mesh));
    }
}
const materialNames = isBMW
    ? {BMW_E30_M3_PAINT:'Body_Color', BMW_E30_M3_TIRE:'Tires', BMW_E30_M3_WINDOWS:'window', BMW_E30_M3_BLACKOUT:'InteriorBlocker', BMW_E30_M3_TAILLIGHT_REFLECTOR:'Taillight_Glass'}
    : {RRpbrPaintPrimary:'Body_Color', 'Scene_-_Root.002':'Tires', RLA_miata_glass:'window', RLA_miata_glass_int:'window', RLA_miata_brakelight:'Taillight_Glass'};
for (const material of root.listMaterials()) {
    const name = materialNames[material.getName()];
    if (name) material.setName(name);
}
root.setDefaultScene(scene);
for (const old of root.listScenes()) if (old !== scene) old.dispose();
for (const node of originals) node.dispose();
for (const extension of root.listExtensionsUsed()) {
    if (extension.extensionName === 'EXT_meshopt_compression') extension.dispose();
}
await document.transform(prune());
await io.write(destination, document);
console.log({ model, track, wheelbase, frontAxle: wheelbase/2, radius });
