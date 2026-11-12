# Additional vehicles

## Ferrari 458

Model: **vicent091036**, CC BY 4.0. Original model: https://sketchfab.com/models/57bf6cc56931426e87494f554df1dab6 . Distributed by the official three.js example: https://github.com/mrdoob/three.js/blob/dev/examples/webgl_materials_car.html . License recorded by the three.js maintainers: https://github.com/mrdoob/three.js/issues/23089 . License text: https://creativecommons.org/licenses/by/4.0/legalcode .

`Ferrari458.glb` is an adapted copy: Draco decoded, mesh transforms baked, forward axis rotated, origin adjusted and wheels/steering regrouped. Runtime materials, instrument display, animations and bounded body deformation are APEX Lab adaptations. The vehicle has the detailed cabin provided by its author. The source contains 458 Spider markings; the app uses the general 458 label.

## Porsche 911 Carrera 4S

Model: **Lionsharp Studios / Karol Miklas**, CC BY-SA 4.0. Original: https://sketchfab.com/3d-models/free-porsche-911-carrera-4s-d01b254483794de3819786d93e0e1ebf . Official PlayCanvas distribution and license: https://github.com/playcanvas/web-components/tree/main/examples/assets/models . License text: https://creativecommons.org/licenses/by-sa/4.0/legalcode .

`Porsche911.glb` and the Porsche model adaptations remain available under **CC BY-SA 4.0**, including the adapted appearance rendered by the application. Adaptations: Draco decoding, mesh transforms baked into metres, ground origin adjustment, baked ground shadow and duplicate clearcoat shell removed, axle meshes split into left/right wheel groups and front display pose neutralized (+20° yaw correction in 1.4, replacing the incorrect -0.18 rad adjustment); neutral front wheel centres made symmetric to match the contact patches. Runtime materials, simplified cabin fixtures, instrumentation, wheel animation with non-spinning Porsche calipers and bounded deformation are adaptations. The source is exterior-focused; the added cabin is a generic prototype, not a reproduction of a Porsche interior.

Vehicle designs, emblems, names and source-model number plates belong to their respective owners. They are retained as part of the openly licensed models; no manufacturer affiliation or endorsement is claimed. Dynamics presets and the shared engine audio are experimental and are not recordings or calibrated simulations of these cars. All presets currently use the project's rear-wheel-drive drivetrain, including the 4S visual model.

## Reproducing the conversion

Normal builds use the committed GLB files and require no npm packages or downloads. `sources.json` records upstream URLs and SHA-256 values. For asset maintenance only, install `@gltf-transform/core`, `@gltf-transform/extensions`, `@gltf-transform/functions` 4.5.1 and `draco3dgltf` 1.5.7 in an ignored temporary tool directory; copy `Tools/prepare_vehicles.mjs` into that directory, then run:

```sh
node prepare_vehicles.mjs ferrari.glb Ferrari458.glb ferrari
node prepare_vehicles.mjs porsche.glb Porsche911.glb porsche
```

Keep this notice, source credits and the corresponding Creative Commons license with redistributed models and adaptations. Public game screenshots should also retain the model credit or place it in the accompanying caption.

## BMW M3 E30 and Mazda MX-5 (1.8)

- **BMW M3 E30** by **Martin Trafas**. [Original model](https://sketchfab.com/3d-models/free-bmw-m3-e30-ac3c7013434e403e8faff87948caf422) and [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **Mazda Miata mx-5** by **Black Snow**. [Original model](https://sketchfab.com/3d-models/mazda-miata-mx-5-e074e29ccc3847dca74ed5e9cb92d3e7) and [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

The downloaded assets were obtained from the `carros` distribution. Its catalog records the original author and license. [Model licensing and redistribution credits](https://github.com/pedrosoandre/carros/blob/main/LICENSE-3D-MODELS.md).

APEX Lab decoded Meshopt and quantized attributes, baked the original transforms, centered and aligned the four wheels, neutralized the BMW front steering and Mazda tire camber, separated rolling meshes from calipers, and adapted materials, instruments and body deformation. The BMW uses the prototype's simplified cabin. The Mazda retains its modelled interior and steering wheel. Both use experimental rear-wheel-drive presets. Source and output SHA-256 values are listed in `sources.json`.

To reproduce these adaptations, place `Tools/prepare_club_cars.mjs` in the offline asset tool directory with the glTF Transform packages listed above and `meshoptimizer` 1.3.0. Run `node prepare_club_cars.mjs input.glb output.glb bmw` or use `mazda` for the MX-5.
