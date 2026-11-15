# Additional vehicles

## Ferrari 458

Model: **vicent091036**, CC BY 4.0. Original model: https://sketchfab.com/models/57bf6cc56931426e87494f554df1dab6 . Distributed by the official three.js example: https://github.com/mrdoob/three.js/blob/dev/examples/webgl_materials_car.html . License recorded by the three.js maintainers: https://github.com/mrdoob/three.js/issues/23089 . License text: https://creativecommons.org/licenses/by/4.0/legalcode .

`Ferrari458.glb` is an adapted copy: Draco decoded, mesh transforms baked, forward axis rotated, origin adjusted and wheels/steering regrouped. APEX Lab adapts runtime materials, wheel animations, bounded body deformation and real-time reflections on the source mirror surfaces. The vehicle has the detailed cabin provided by its author. The source contains 458 Spider markings; the app uses the general 458 label.

## Porsche 911 Carrera 4S (992), Lotus Elise and Honda e

- **Porsche 911 C4S 2020 Aerokit** by **JK3Dstudios**. [Original 992 model](https://sketchfab.com/3d-models/porsche-911-c4s-2020-aerokit-ee69c474a1cc4085944cde4cb7ae87db).
- **Lotus Élise** by **Stéphane Agullo**. [Original model](https://sketchfab.com/3d-models/lotus-elise-75e9045ac1af4cdbb69318108c81edfd).
- **Honda e (Detailed Interior) 2021** by **Alex Murias** (Xlay3D). [Original model](https://sketchfab.com/3d-models/free-honda-e-detailed-interior-2021-814cf3f8cfd64594b1c4f96e873c3cef).

All three are licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and retain the source exteriors, interior meshes and textures. APEX Lab bakes the transforms and binds wheels, steering, glazed surfaces, tail lamps and mirrors. The Lotus import uses the author’s closed driving pose without the showcase driver and stage. The Honda import reduces subdivisions for real-time rendering and binds its original digital side and rear screens. The former 911 exterior by Lionsharp Studios / Karol Miklas remains documented in the earlier releases under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

Vehicle designs, emblems, names and source-model number plates belong to their respective owners. Simulation presets and the audio are experimental. The 911 uses experimental all-wheel drive with a nominal 30% front torque split.

## Reproducing the conversion

Normal builds use the committed GLB files and require no npm packages or downloads. `sources.json` records upstream URLs and SHA-256 values. For asset maintenance only, install `@gltf-transform/core`, `@gltf-transform/extensions`, `@gltf-transform/functions` 4.5.1 and `draco3dgltf` 1.5.7 in an ignored temporary tool directory; copy `Tools/prepare_vehicles.mjs` and `Tools/prepare_grid_cars.mjs` into that directory. For Honda simplification, also install `meshoptimizer` 1.3.0. Then run:

```sh
node prepare_vehicles.mjs ferrari.glb Ferrari458.glb ferrari
node prepare_grid_cars.mjs porsche.glb Porsche911.glb porsche
node prepare_grid_cars.mjs lotus.glb LotusElise.glb lotus
node prepare_grid_cars.mjs honda.glb HondaE.glb honda
```

Keep this notice, source credits and the corresponding Creative Commons license with redistributed models and adaptations. Public game screenshots should also retain the model credit or place it in the accompanying caption.

## BMW M3 E30 and Mazda MX-5 NA

- **BMW M3 E30** by **Artem P**. [Original model](https://sketchfab.com/3d-models/bmw-m3-e30-6d67d12a2abe4e119842f65e46fa2f67) and [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **Mazda Miata MX-5 NA** by **Lexyc16**. [Original model](https://sketchfab.com/3d-models/mazda-miata-mx-5-na-d51fcd44b74f4daf8012c41e0400c041) and [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

The source GLBs are archived by AI2 Objaverse. Their exact URLs and file hashes are in `sources.json`. The converted models use the authors' bodywork, interior meshes, textures and paint. APEX Lab bakes transforms, aligns the origins, wheelbase, track and rolling radius to the in-game presets and isolates the authored steering meshes, BMW calipers, Mazda third brake light and mirror faces for animation and reflection. The conversion omits the BMW showcase floor and undercarriage suspension mesh, and the Mazda showcase animation.

To rebuild either asset, put `Tools/prepare_authored_cars.mjs` in the asset tool directory with the glTF Transform packages listed above. Run `node prepare_authored_cars.mjs source.glb BMWM3E30.glb bmw` or `node prepare_authored_cars.mjs source.glb MazdaMX5.glb mazda`.

## Lamborghini Centenario LP-770 (1.13)

**Lamborghini Centenario LP-770 Interior SDC** by **SDC PERFORMANCE™️**, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author's original model](https://sketchfab.com/3d-models/lamborghini-centenario-lp-770-interior-sdc-d679af35b5694301a185c7454a700c73) · [Full-resolution archived GLB](https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-131/d679af35b5694301a185c7454a700c73.glb).

APEX Lab retains the 325,733 source triangles, original materials, and all seven embedded texture images byte for byte. The conversion bakes transforms, centers the origin, splits the wheel and brake meshes, neutralizes the display steering angle, and binds the original steering wheel. It uses the static closed-door model in the racing scene and omits the showcase animation. The app hides the original window tint in interior driving views and binds the original brake-light mesh. The author describes the interior as their interpretation of the Centenario. The 2.0 driving preset uses an experimental all-wheel-drive six-speed with a nominal 35% front torque split and a synthesized V12 sound as of 2.0 RC11.

To reproduce the conversion, run `node prepare_centenario.mjs input.glb Centenario.glb` with the glTF Transform 4.5.1 packages and Meshoptimizer 1.3.0 in the offline tool directory. Both hashes are in `sources.json`.
