// Converts the attributed Objaverse archive for SceneKit. No mesh or texture is authored here.
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { compactPrimitive, dequantize, prune, transformPrimitive } from '@gltf-transform/functions';
import { MeshoptDecoder } from 'meshoptimizer';

const [source, destination] = process.argv.slice(2);
await MeshoptDecoder.ready;
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'meshopt.decoder':MeshoptDecoder});
const document = await io.read(source);
await document.transform(dequantize());
const root = document.getRoot();
const originalScene = root.getDefaultScene();
const nodes = [...root.listNodes()];
const scene = document.createScene('Centenario driving pose');
const rearParts = new Set(['Object_4','Object_5','Object_6','Object_7','Object_8','Object_9','Object_10']);
const frontParts = new Set(['Object_14','Object_15','Object_16','Object_17','Object_18','Object_19','Object_20','Object_21']);
const axle = { F:1.1975, R:-1.49425 };
const ground = 0.0187;
const midpoint = (axle.F+axle.R)/2;
const wheels = new Map();
const transform = (x,y,z,yaw=0) => {
    const c = Math.cos(yaw), s = Math.sin(yaw);
    return [c,0,-s,0,0,1,0,0,s,0,c,0,x,y,z,1];
};
const body = document.createNode('OriginalBody');
const steeringPivot = [0.356,0.762,0.115];
const steering = document.createNode('Steering').setTranslation([steeringPivot[0],steeringPivot[1]-ground,steeringPivot[2]-midpoint]);
scene.addChild(body).addChild(steering);
function add(parent, primitive, name) {
    parent.addChild(document.createNode(name).setMesh(document.createMesh(name).addPrimitive(primitive)));
}
const primitiveCount = primitive => primitive.getIndices().getCount()/3;
let inputTriangles = 0, outputTriangles = 0;
for (const node of nodes) {
    for (const source of node.getMesh()?.listPrimitives() ?? []) {
        inputTriangles += primitiveCount(source);
        const original = source.clone();
        compactPrimitive(original);
        transformPrimitive(original,node.getWorldMatrix());
        const name = node.getName();
        const end = frontParts.has(name) ? 'F' : rearParts.has(name) ? 'R' : null;
        if (!end) {
            const isSteering = node.getParentNode()?.getName() === 'movsteer_1.0_7';
            transformPrimitive(original,isSteering ? transform(...steeringPivot.map(x=>-x)) : transform(0,-ground,-midpoint));
            add(isSteering ? steering : body,original,name);
            outputTriangles += primitiveCount(original);
            continue;
        }
        const vertices = original.getAttribute('POSITION').getArray();
        const indices = original.getIndices();
        const values = indices.getArray();
        const left = [], right = [];
        for (let i = 0; i < values.length; i += 3) {
            const triangle = [values[i], values[i+1], values[i+2]];
            const sign = vertices[3*triangle[0]] > 0;
            if (!triangle.every(index => (vertices[3*index] > 0) === sign)) throw new Error('Unexpected triangle spanning the two wheels');
            (sign ? left : right).push(...triangle);
        }
        for (const [side, triangles] of [['L',left],['R',right]]) {
            if (!triangles.length) continue;
            const sign = side === 'L' ? 1 : -1;
            const key = 'Wheel'+end+side;
            const centre = [sign*(end === 'F' ? 0.848 : 0.849), end === 'F' ? 0.3813 : 0.3957, axle[end]];
            if (!wheels.has(key)) {
                const wheel = document.createNode(key).setTranslation([centre[0],centre[1]-ground,centre[2]-midpoint]);
                scene.addChild(wheel); wheels.set(key,wheel);
            }
            const half = original.clone();
            half.setIndices(indices.clone().setArray(new values.constructor(triangles)));
            compactPrimitive(half);
            transformPrimitive(half,transform(...centre.map(x=>-x)));
            if (end === 'F') {
                // Align each authored sidewall plane with the simulation axle.
                const yaw = side === 'L' ? -0.40257 : -0.35339;
                transformPrimitive(half,transform(0,0,0,yaw));
            }
            add(wheels.get(key),half,name);
            outputTriangles += primitiveCount(half);
        }
        original.dispose();
    }
}
if (inputTriangles !== outputTriangles || wheels.size !== 4) throw new Error('Import must retain every triangle and produce four wheels');
for (const animation of root.listAnimations()) animation.dispose();
root.setDefaultScene(scene);
originalScene.dispose();
for (const node of nodes) node.dispose();
for (const extension of root.listExtensionsUsed()) {
    if (extension.extensionName === 'EXT_meshopt_compression') extension.dispose();
}
await document.transform(prune());
await io.write(destination,document);
console.log({inputTriangles,outputTriangles,wheels:wheels.size});
