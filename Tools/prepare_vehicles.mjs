// Offline asset adaptation. Run from the documented temporary npm toolchain.
// Arguments: source.glb destination.glb ferrari|porsche. No runtime JS dependency.
import {NodeIO} from '@gltf-transform/core';
import {ALL_EXTENSIONS} from '@gltf-transform/extensions';
import {transformPrimitive, prune, dequantize} from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';
const [source,destination,kind]=process.argv.slice(2);
if (!['ferrari','porsche'].includes(kind)) throw new Error('Unknown vehicle');
const io=new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder':await draco3d.createDecoderModule()});
const doc=await io.read(source);
await doc.transform(dequantize());
const root=doc.getRoot(), nodes=[...root.listNodes()], scene=doc.createScene('Driving vehicle');
const buffer=root.listBuffers()[0];
const buckets=new Map();
function add(key,name,prim){
 if(!buckets.has(key)){const n=doc.createNode(key);scene.addChild(n);buckets.set(key,n);}
 const mesh=doc.createMesh(name).addPrimitive(prim);
 buckets.get(key).addChild(doc.createNode(name).setMesh(mesh));
}
function clonePrimitive(p){
 const q=p.clone();
 for(const semantic of p.listSemantics())q.setAttribute(semantic,p.getAttribute(semantic).clone().setArray(p.getAttribute(semantic).getArray().slice()));
 if(p.getIndices())q.setIndices(p.getIndices().clone().setArray(p.getIndices().getArray().slice()));
 return q;
}
for(const n of nodes){
 if(!n.getMesh())continue;
 const name=n.getName();
 const ancestors=[];for(let a=n;a;a=a.getParentNode())ancestors.push(a.getName());
 for(const src of n.getMesh().listPrimitives()){
  const mat=src.getMaterial()?.getName()??'';
  // Remove the baked ground shadow and duplicate clearcoat shell, not car geometry.
  if(kind==='porsche' && (name==='Plane_0'||mat==='coat'))continue;
  const p=clonePrimitive(src);transformPrimitive(p,n.getWorldMatrix());
  const fix=kind==='ferrari'?[-1,0,0,0,0,1,0,0,0,0,-1,0,0,0,0.17,1]:[1,0,0,0,0,1,0,0,0,0,1,0,0.015285,0.632514,-0.053,1];
  transformPrimitive(p,fix);
  if(kind==='ferrari'){
   const w=ancestors.find(a=>/^wheel_[fr][lr]$/.test(a));
   const key=w?({wheel_fr:'WheelFR',wheel_fl:'WheelFL',wheel_rr:'WheelRR',wheel_rl:'WheelRL'}[w]):ancestors.includes('steering_wheel')?'Steering':'Body';
   add(key,name,p);
  } else if(ancestors.some(a=>a==='Cylinder.000'||a==='Cylinder.001')){
   // Source stores each axle as one mesh: split indexed triangles by vehicle side.
   for(const side of [-1,1]){
    const indices=p.getIndices().getArray(),pos=p.getAttribute('POSITION').getArray(),out=[];
    for(let i=0;i<indices.length;i+=3){const x=(pos[indices[i]*3]+pos[indices[i+1]*3]+pos[indices[i+2]*3])/3;if((x<0?-1:1)===side)out.push(indices[i],indices[i+1],indices[i+2]);}
    if(!out.length)continue;
    const q=clonePrimitive(p);q.setIndices(doc.createAccessor().setType('SCALAR').setArray(new Uint32Array(out)).setBuffer(buffer));
    add('Wheel'+(ancestors.includes('Cylinder.001')?'F':'R')+(side<0?'R':'L'),name,q);
   }
  }else add('Body',name,p);
 }
}
for(const [key,group] of buckets){
 if(key==='Body')continue;
 const lo=[Infinity,Infinity,Infinity],hi=[-Infinity,-Infinity,-Infinity];
 for(const n of group.listChildren())for(const p of n.getMesh().listPrimitives()){
  const a=p.getAttribute('POSITION').getArray();
  for(const i of p.getIndices().getArray())for(let k=0;k<3;k++){lo[k]=Math.min(lo[k],a[3*i+k]);hi[k]=Math.max(hi[k],a[3*i+k]);}
 }
 const center=lo.map((x,k)=>(x+hi[k])/2);
 // Symmetric unsteered wheel centers; Porsche front source has a display steering pose.
 for(const n of group.listChildren())for(const p of n.getMesh().listPrimitives()){
  transformPrimitive(p,[1,0,0,0,0,1,0,0,0,0,1,0,-center[0],-center[1],-center[2],1]);
  if(kind==='porsche'&&key.startsWith('WheelF')){
   // Source front tyres have -20 degrees of yaw. Undo it before X-axis roll;
   // the former -0.18 rad correction compounded the pose and made them wobble.
   const a=20*Math.PI/180,c=Math.cos(a),s=Math.sin(a);transformPrimitive(p,[c,0,-s,0,0,1,0,0,s,0,c,0,0,0,0,1]);
  }
 }
 group.setTranslation(center);
 console.log(key,center);
}
if(kind==='porsche'){
 // The display steering pose also offsets the front bounding-box centres.
 // Restore a symmetric neutral axle, matching the straight rear track.
 const fr=buckets.get('WheelFR'),fl=buckets.get('WheelFL');
 const halfTrack=(Math.abs(buckets.get('WheelRR').getTranslation()[0])+Math.abs(buckets.get('WheelRL').getTranslation()[0]))/2;
 const z=(fr.getTranslation()[2]+fl.getTranslation()[2])/2;
 fr.setTranslation([-halfTrack,fr.getTranslation()[1],z]);
 fl.setTranslation([halfTrack,fl.getTranslation()[1],z]);
}
root.setDefaultScene(scene);
for(const s of [...root.listScenes()])if(s!==scene)s.dispose();
for(const n of nodes)n.dispose();
for(const ext of root.listExtensionsUsed())if(ext.extensionName==='KHR_draco_mesh_compression')ext.dispose();
await doc.transform(prune());
await io.write(destination,doc);
