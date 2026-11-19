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

“Car Engine Loop 96kHz, 4s” by qubodup, used under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Original recording and author credits](https://opengameart.org/content/car-engine-loop-96khz-4s). The bundled `Audio/engine-recording.wav` is the original normalized 44.1 kHz stereo loop. Playback mixes it to mono, crossfades the loop seam, adjusts pitch with RPM, uses different cabin and exterior filtering and blends in a recorded load layer. These adaptations also appear in the driving audio preview.

## Recorded powertrains and tyre scrub (3.0 Preview 22)

The following excerpts use the authors’ published field recordings. The engine layers were trimmed from the public HQ previews, downmixed to mono, band-limited, gain-adjusted and converted to 44.1 kHz PCM. Playback crossfades the loop and changes its rate. Each of the five Freesound powertrain recordings below is available under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). Their use in APEX Lab and the bundled driving demonstration is summarized below. Exact vehicle versions, measured shaft speeds and microphone perspectives vary between reference vehicles and game presets.

| Bundled file | Model use and modification | Author and original recording |
| --- | --- | --- |
| `Audio/inline-load.wav` | Four-cylinder load layer from 13.65–14.40 s of a 2019 Mini Cooper S recording. The recordist placed contact mics on the chassis and engine. | TheLittleCrow, [Gunning it](https://freesound.org/people/TheLittleCrow/sounds/669622/) |
| `Audio/flat-six.wav` | Material for the 911 from 1.70–2.45 s of a Porsche 911 in Barcelona. Generation unspecified. | mharo, [porsche_911.wav](https://freesound.org/people/mharo/sounds/55727/) |
| `Audio/ferrari-exhaust.wav` | Ferrari exhaust layer from 2.10–4.20 s. The source author does not identify the model. | EwanPenman11, [Ferrari Engine (passive)](https://freesound.org/people/EwanPenman11/sounds/659554/) |
| `Audio/v12.wav` | Centenario V12 reference from 22.30–23.60 s of a recording tagged Murciélago LP670. | cheesepuff, [Lambo idle and rev](https://freesound.org/people/cheesepuff/sounds/112075/) |
| `Audio/electric.wav` | Honda e electric-drive reference from 2.40–3.12 s of a Tesla Model S Plaid acceleration. | justVova, [Acceleration of an electric car](https://freesound.org/people/justVova/sounds/761685/) |

`Audio/tyre-skid.wav` is adapted from “Car tire squeal skid loop,” submitted by qubodup. Tom Haigh (audible-edge) recorded his 1996 Chrysler LHS driving around a microphone. Qubodup edited the recording into a three-second loop. The bundled copy is resampled from 96 kHz/24-bit to 44.1 kHz/16-bit, and the game drives its gain, filtering, rate and pan. The loop and its use in the demonstration are credited under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Original field recording](https://freesound.org/people/audible-edge/sounds/71739/) · [Loop source and license](https://opengameart.org/content/car-tire-squeal-skid-loop).

## Driving audio additions (3.0 Preview 23)

For Preview 23, the earlier flat-six, V12 and inline-load excerpts were also retimed to reduce periodic pitch sweeps at constant engine speed. The flat-six excerpt uses the material from approximately 1.86–2.45 s of the original source.

The following recordings are included as PCM excerpts. The engine excerpts were mixed to mono, filtered, gain-adjusted, and retimed to hold an approximately steady firing frequency before the game's RPM-based playback. The eight-car WAV demonstration uses these same sources.

| Files | Recording and excerpt | Attribution and licence |
| --- | --- | --- |
| `Audio/mx5-idle.wav`, `Audio/mx5-mid.wav`, `Audio/mx5-load.wav` | Mazda MX-5 / Eunos Roadster with aftermarket HKS exhaust. Low 33.12–34.82 s, mid 3.72–5.46 s, high 28.42–29.34 s. | Walter_Odington, [car revving.aif](https://freesound.org/people/Walter_Odington/sounds/18620/), [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). |
| `Audio/elise-exhaust.wav` | Lotus Elise, 41.57–42.56 s. | A Common Thread, [Car Engine Sounds – Lotus Elise](https://www.youtube.com/watch?v=uHTdmWRS1nM), [Wikimedia Commons copy](https://commons.wikimedia.org/wiki/File:Lotus_Elise_-_engine_and_exhaust_sound_%28YouTube_uHTdmWRS1nM%29.opus), [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). |
| `Audio/e30-exhaust.wav` | E30 318is, 10.67–11.90 s, used as a four-cylinder reference for the M3 E30 preset. | Pieter Van Nevel, [BMW E30 318IS Acceleration Sound](https://www.youtube.com/watch?v=KIcw74dVbcY), [Wikimedia Commons copy](https://commons.wikimedia.org/wiki/File:BMW_E30_-_engine_and_exhaust_sound_%28YouTube_KIcw74dVbcY%29.opus), [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). |
| `Audio/road-roll.wav` | Interior recording on a Belgian motorway, 2.00–8.25 s, downmixed, filtered from 155 Hz to 2.75 kHz, resampled and gain-adjusted. | gecop, [Highway drive interior](https://freesound.org/people/gecop/sounds/521766/), [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). |

## Ferrari 458 recording (3.0 Preview 24)

`Audio/ferrari-mid.wav` and `Audio/ferrari-high.wav` are derived from FiExhaust's recording of a Ferrari 458 Italia fitted with its aftermarket exhaust. APEX Lab downmixed excerpts at 90.00–91.72 s and 107.50–109.80 s to mono, level-matched them and retimed the engine harmonics to hold steady playback pitches. The in-game mix and audio demonstrations use these excerpts. [Original recording and attribution](https://commons.wikimedia.org/wiki/File:Ferrari_458_Italia_with_Fi_Exhaust_-_engine_and_exhaust_sound_%28YouTube_bGvBhSWv1dw%29.opus) · [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).

## Lotus Elise recording (3.0 Preview 24)

`Audio/elise-low.wav` uses the settled idle at 10.96–12.13 s. `Audio/elise-high.wav` uses the rev at 31.29–31.99 s. APEX Lab downmixed, filtered, retimed and level-matched the excerpts for approximately 835 and 5966 rpm playback anchors. Both the game and the demonstrations use these adaptations. A Common Thread, [Car Engine Sounds – Lotus Elise](https://commons.wikimedia.org/wiki/File:Lotus_Elise_-_engine_and_exhaust_sound_%28YouTube_uHTdmWRS1nM%29.opus), [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).

## BMW E30 recording (3.0 Preview 24)

`Audio/e30-low.wav` and `Audio/e30-high.wav` use 0.380–1.055 s and 8.830–9.490 s from Pieter Van Nevel's E30 318is recording. The M3 E30 preset borrows these low and high four-cylinder references. APEX Lab downmixed, filtered and level-matched the excerpts, retaining the natural idle variation and retiming the higher excerpt to a steady pitch. Reference speeds of about 810 and 5007 rpm are acoustic estimates. [BMW E30 318IS Acceleration Sound](https://commons.wikimedia.org/wiki/File:BMW_E30_-_engine_and_exhaust_sound_%28YouTube_KIcw74dVbcY%29.opus) · [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).

## Additional vehicles (1.2)

- **Ferrari 458** — vicent091036, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author model](https://sketchfab.com/models/57bf6cc56931426e87494f554df1dab6), distributed through the [official three.js example](https://github.com/mrdoob/three.js/blob/dev/examples/webgl_materials_car.html).
- **Porsche 911 Carrera 4S (992)** — JK3Dstudios, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author model](https://sketchfab.com/3d-models/porsche-911-c4s-2020-aerokit-ee69c474a1cc4085944cde4cb7ae87db).
- **Lotus Elise** — Stéphane Agullo, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author model](https://sketchfab.com/3d-models/lotus-elise-75e9045ac1af4cdbb69318108c81edfd).
- **Honda e** — Alex Murias, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author model](https://sketchfab.com/3d-models/free-honda-e-detailed-interior-2021-814cf3f8cfd64594b1c4f96e873c3cef).

See [Vehicles/README.md](Vehicles/README.md) for conversion and redistribution details.

## BMW M3 E30 and Mazda MX-5 NA

BMW M3 E30 by Artem P and Mazda Miata MX-5 NA by Lexyc16, each under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Original model links, distribution sources, hashes and modifications are in [Vehicles/README.md](Vehicles/README.md).

## Lamborghini Centenario LP-770

Model and textures by **SDC PERFORMANCE™️**, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Original model and author attribution](https://sketchfab.com/3d-models/lamborghini-centenario-lp-770-interior-sdc-d679af35b5694301a185c7454a700c73) · [Archive and adaptation details](Vehicles/README.md).

## Recorded engine load and overrun references (3.0 Preview 24)

The `gt3rs-{on,off}-{3000,6000}.wav` clips use Porsche 911 GT3 RS recordings for the 911 4S preset. The `svj-{on,off}-{3000,6000}.wav` clips use the Aventador family for the Centenario preset. The upstream pack labelled on/off sections of public recordings from their rev trajectories. These labels estimate driving state from sound and the RPM values are acoustic estimates. APEX Lab resampled the selected loops to mono 44.1 kHz PCM, adjusted their gain, and blends them with the existing low-RPM recordings according to simulated shaft speed and work. The driving demonstration uses the same adaptations. [Upstream selection, author credits and processing](https://github.com/justinagaudelli-eng/supercar-engine-sound/blob/3a3875f33f4025b05472bc1312eba1b3e0debac7/public/samples/CREDITS.md). All six credited source recordings are licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).

- Supercars67 — [Porsche 911 GT3 RS engine and exhaust, 1t2wz1iLHJ4](https://commons.wikimedia.org/wiki/File:Porsche_911_GT3_RS_-_engine_and_exhaust_sound_%28YouTube_1t2wz1iLHJ4%29.opus).
- NEW CARS 2015 Official — [Porsche 911 GT3 RS engine and exhaust, hpwTF8TXcaA](https://commons.wikimedia.org/wiki/File:Porsche_911_GT3_RS_-_engine_and_exhaust_sound_%28YouTube_hpwTF8TXcaA%29.opus).
- Automotion Media — [Porsche 911 GT3 RS (991) engine and exhaust](https://commons.wikimedia.org/wiki/File:Porsche_911_GT3_RS_%28991%29_-_engine_and_exhaust_sound_%28YouTube_otznJ2rBoks%29.opus).
- Super Cars for you — [Lamborghini Aventador engine and exhaust](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_-_engine_and_exhaust_sound_%28YouTube_oMKxhIcSmZs%29.opus).
- Erwin Lindsen — [Lamborghini Aventador SV engine and exhaust](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_SV_-_engine_and_exhaust_sound_%28YouTube_qll6WBfaXvM%29.opus).
- ePic eXhaust — [Lamborghini Aventador SVJ engine and exhaust](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_SVJ_-_engine_and_exhaust_sound_%28YouTube_zqv9zLtHsUM%29.opus).
