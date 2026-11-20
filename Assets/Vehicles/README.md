# Licensed vehicle assets

The game uses the two credited models below. `Showcase.json` maps existing mesh primitives to doors, compartment lids and lamps. The driving scene binds the original wheels, steering and reflective surfaces. The showroom retains the original triangles, textures and UVs.

## Porsche 911 Carrera 4S (992)

**Porsche 911 C4S 2020 Aerokit** by **JK3Dstudios**, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Original model](https://sketchfab.com/3d-models/porsche-911-c4s-2020-aerokit-ee69c474a1cc4085944cde4cb7ae87db).

The conversion bakes model transforms, aligns wheels and steering with the driving preset and isolates the authored glazing, rear lamps and mirrors. The showroom binds the original door shells, door trim, front lid and lamps. The driving cockpit preserves the interior atlas and uses a matte cabin finish. The exterior windshield frame is present in exterior views. The 911 uses an experimental all-wheel-drive preset with a nominal 30% front torque split.

## Lamborghini Centenario LP-770

**Lamborghini Centenario LP-770 Interior SDC** by **SDC PERFORMANCE™️**, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Original model](https://sketchfab.com/3d-models/lamborghini-centenario-lp-770-interior-sdc-d679af35b5694301a185c7454a700c73).

The conversion retains the 325,733 source triangles, original materials and seven embedded texture images. It bakes transforms, centers the origin, splits the wheels and brakes, neutralizes the display steering angle and binds the original steering wheel. The showroom separates the authored scissor doors, front lid, rear engine lid and lamps. Runtime surface finishes retain the source textures on the dashboard and inner door panels. Cabin inspection clears the source tint while exterior views retain the original windshield and side glazing. The author describes the interior as their interpretation of the Centenario. The driving preset uses experimental all-wheel drive with a nominal 35% front torque split.

## Reproducing the conversions

The bundled GLBs work without package installation or downloads. For asset maintenance, `sources.json` records the upstream archive URLs and original and converted SHA-256 digests. Install `@gltf-transform/core`, `@gltf-transform/extensions` and `@gltf-transform/functions` 4.5.1 in an ignored tool directory. Install `meshoptimizer` 1.3.0 for `prepare_centenario.mjs`. Copy the corresponding import scripts from `Tools/` into that directory.

```sh
node prepare_porsche.mjs porsche.glb Porsche911.glb
node prepare_centenario.mjs centenario.glb Centenario.glb
```

The vehicle designs, names, emblems and source-model plates belong to their respective owners. Retain these notices, author credits and applicable Creative Commons licenses when redistributing the models, adaptations or vehicle preview artwork.
