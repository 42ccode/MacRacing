# Third-party asset notices

## Car Concept

Model and textures: **Eric Chadwick**, copyright **2024 Darmstadt Graphics Group GmbH**.

Source: [Khronos glTF Sample Assets — Car Concept](https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/CarConcept).

License: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/).

The original `CarConcept.glb`, metadata and README are included. The application converts its coordinates at runtime, neutralizes the authored front-wheel steering pose, animates wheels/steering/brake lights, changes body and cockpit materials, adds a prototype rear wing, applies bounded exterior panel deformation and wheel/wing damage poses in 1.0, and approximates glTF transmission in SceneKit. The demonstration vehicle's appearance does not establish real-world dynamics parameters.

Khronos and 3D Commerce logos are retained within the model as provided. Those marks remain owned by The Khronos Group; the model license does not grant rights to use them outside this context. This application is not affiliated with or endorsed by Khronos or Darmstadt Graphics Group.

## Poly Haven

All following assets are provided under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/); source metadata and file manifests are included.

| Asset | Creator | Source |
| --- | --- | --- |
| Asphalt 02 | Rob Tuytel | https://polyhaven.com/a/asphalt_02 |
| Aerial Grass Rock | Rob Tuytel | https://polyhaven.com/a/aerial_grass_rock |
| Industrial Sunset 02 (Pure Sky) | Jarod Guest, sky edits; Sergej Majboroda, original | https://polyhaven.com/a/industrial_sunset_02_puresky |

The downloaded texture and HDR files were checked against the MD5 digests in the official file manifests. The application tiles the textures and uses the HDR image for background and environmental lighting.

## Circuit Test (0.3) scenery

The following Poly Haven assets are CC0. Trees are rendered from the original 3D model into four directional images offline; their positions, rotations, heights and terrain are original. The shrub and concrete barrier source textures are retained in the authoring library. The driving surface, track layout and scenery are not iRacing assets.

| Asset | Creator | Source |
| --- | --- | --- |
| Kloofendal 48d Partly Cloudy | Greg Zaal | https://polyhaven.com/a/kloofendal_48d_partly_cloudy |
| Asphalt Track | Dimitrios Savva | https://polyhaven.com/a/asphalt_track |
| Grass Ground | Charlotte Baglioni | https://polyhaven.com/a/grass_ground |
| Metal Plate | Rob Tuytel | https://polyhaven.com/a/metal_plate |
| Concrete Wall 006 | Charlotte Baglioni (photography), Dario Barresi (processing) | https://polyhaven.com/a/concrete_wall_006 |
| Tree Small 02 | Rico Cilliers | https://polyhaven.com/a/tree_small_02 |
| Shrub 01 | Rico Cilliers | https://polyhaven.com/a/shrub_01 |
| Concrete Road Barrier | Amal Kumar | https://polyhaven.com/a/concrete_road_barrier |

## Engine recording (0.4)

“Car Engine Loop 96kHz, 4s” by qubodup, used under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Original recording and author credits](https://opengameart.org/content/car-engine-loop-96khz-4s). The bundled `Audio/engine-recording.wav` is the original normalized 44.1 kHz stereo loop. Playback mixes it to mono, crossfades the loop seam, adjusts pitch with RPM, changes the cabin/exterior filtering and adds procedural combustion and intake layers. These adaptations also appear in the driving audio preview.

## Additional vehicles (1.2)

- **Ferrari 458** — vicent091036, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author model](https://sketchfab.com/models/57bf6cc56931426e87494f554df1dab6), distributed through the [official three.js example](https://github.com/mrdoob/three.js/blob/dev/examples/webgl_materials_car.html).
- **Porsche 911 Carrera 4S** — Lionsharp Studios / Karol Miklas, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). [Author model](https://sketchfab.com/3d-models/free-porsche-911-carrera-4s-d01b254483794de3819786d93e0e1ebf), distributed through [PlayCanvas](https://github.com/playcanvas/web-components/tree/main/examples/assets/models). The adapted Porsche model and model appearance remain under CC BY-SA 4.0.

Both models are decoded and adapted for the native renderer, with normalized transforms and separate animated wheels. Runtime paint, instruments and deformation differ from the sources; Porsche uses a generic simplified cabin. See `Vehicles/README.md` for modifications, licensing, source hashes and reproduction instructions. Vehicle names/designs/marks remain their owners' property; no endorsement is claimed. The simulation presets and shared engine sound are not manufacturer-calibrated.
