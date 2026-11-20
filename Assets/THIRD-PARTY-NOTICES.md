# Third-party asset notices

The two `Vehicles/Previews/*.jpg` images are SceneKit renders of the vehicle assets credited below. The images carry the attribution and applicable license of the underlying model. Changes for these previews include studio lighting, camera framing, glazing, and contact shadows.

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
| Kloofendal Overcast (Pure Sky) | Greg Zaal | https://polyhaven.com/a/kloofendal_overcast_puresky |
| Asphalt Track | Dimitrios Savva | https://polyhaven.com/a/asphalt_track |
| Grass Ground | Charlotte Baglioni | https://polyhaven.com/a/grass_ground |
| Metal Plate | Rob Tuytel | https://polyhaven.com/a/metal_plate |
| Concrete Wall 006 | Charlotte Baglioni (photography), Dario Barresi (processing) | https://polyhaven.com/a/concrete_wall_006 |
| Tree Small 02 | Rico Cilliers | https://polyhaven.com/a/tree_small_02 |
| Shrub 01 | Rico Cilliers | https://polyhaven.com/a/shrub_01 |
| Concrete Road Barrier | Amal Kumar | https://polyhaven.com/a/concrete_road_barrier |

## Recorded powertrains and tyre scrub (3.0 Preview 22)

The following excerpts use the authors’ published field recordings. The engine layers were trimmed from the public HQ previews, downmixed to mono, band-limited, gain-adjusted and converted to 44.1 kHz PCM. Playback crossfades the loop and changes its rate. Both Freesound powertrain recordings below are available under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). Their use in APEX Lab is summarized below. Exact vehicle versions, measured shaft speeds and microphone perspectives vary between reference vehicles and game presets.

| Bundled file | Model use and modification | Author and original recording |
| --- | --- | --- |
| `Audio/flat-six.wav` | Material for the 911 from 1.70–2.45 s of a Porsche 911 in Barcelona. Generation unspecified. | mharo, [porsche_911.wav](https://freesound.org/people/mharo/sounds/55727/) |
| `Audio/v12.wav` | Centenario V12 reference from 22.30–23.60 s of a recording tagged Murciélago LP670. | cheesepuff, [Lambo idle and rev](https://freesound.org/people/cheesepuff/sounds/112075/) |

`Audio/tyre-skid.wav` is adapted from “Car tire squeal skid loop,” submitted by qubodup. Tom Haigh (audible-edge) recorded his 1996 Chrysler LHS driving around a microphone. Qubodup edited the recording into a three-second loop. The bundled copy is resampled from 96 kHz/24-bit to 44.1 kHz/16-bit, and the game drives its gain, filtering, rate and pan. The loop is credited under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). [Original field recording](https://freesound.org/people/audible-edge/sounds/71739/) · [Loop source and license](https://opengameart.org/content/car-tire-squeal-skid-loop).

## Driving audio additions (3.0 Preview 23)

The flat-six and V12 excerpts were retimed to reduce periodic pitch sweeps at constant engine speed. The flat-six excerpt uses the material from approximately 1.86–2.45 s of the original source.

The following recordings are included as PCM excerpts. The engine excerpts were mixed to mono, filtered, gain-adjusted, and retimed to hold an approximately steady firing frequency before the game's RPM-based playback.

| Files | Recording and excerpt | Attribution and licence |
| --- | --- | --- |
| `Audio/road-roll.wav` | Interior recording on a Belgian motorway, 2.00–8.25 s, downmixed, filtered from 155 Hz to 2.75 kHz, resampled and gain-adjusted. | gecop, [Highway drive interior](https://freesound.org/people/gecop/sounds/521766/), [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). |

## Porsche 911 Carrera 4S (992)

- **Porsche 911 Carrera 4S (992)** — JK3Dstudios, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Author model](https://sketchfab.com/3d-models/porsche-911-c4s-2020-aerokit-ee69c474a1cc4085944cde4cb7ae87db).

See [Vehicles/README.md](Vehicles/README.md) for conversion and redistribution details.

## Lamborghini Centenario LP-770

Model and textures by **SDC PERFORMANCE™️**, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [Original model and author attribution](https://sketchfab.com/3d-models/lamborghini-centenario-lp-770-interior-sdc-d679af35b5694301a185c7454a700c73) · [Archive and adaptation details](Vehicles/README.md).

## Recorded engine load and overrun references (3.0 Preview 24)

The `gt3rs-{on,off}-{3000,6000}.wav` clips use Porsche 911 GT3 RS recordings for the 911 4S preset. The `svj-{on,off}-{3000,6000}.wav` clips use the Aventador family for the Centenario preset. The upstream pack labelled on/off sections of public recordings from their rev trajectories. These labels estimate driving state from sound and the RPM values are acoustic estimates. APEX Lab resampled the selected loops to mono 44.1 kHz PCM, adjusted their gain, and blends them with the existing low-RPM recordings according to simulated shaft speed and work. [Upstream selection, author credits and processing](https://github.com/justinagaudelli-eng/supercar-engine-sound/blob/3a3875f33f4025b05472bc1312eba1b3e0debac7/public/samples/CREDITS.md). All six credited source recordings are licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).

- Supercars67 — [Porsche 911 GT3 RS engine and exhaust, 1t2wz1iLHJ4](https://commons.wikimedia.org/wiki/File:Porsche_911_GT3_RS_-_engine_and_exhaust_sound_%28YouTube_1t2wz1iLHJ4%29.opus).
- NEW CARS 2015 Official — [Porsche 911 GT3 RS engine and exhaust, hpwTF8TXcaA](https://commons.wikimedia.org/wiki/File:Porsche_911_GT3_RS_-_engine_and_exhaust_sound_%28YouTube_hpwTF8TXcaA%29.opus).
- Automotion Media — [Porsche 911 GT3 RS (991) engine and exhaust](https://commons.wikimedia.org/wiki/File:Porsche_911_GT3_RS_%28991%29_-_engine_and_exhaust_sound_%28YouTube_otznJ2rBoks%29.opus).
- Super Cars for you — [Lamborghini Aventador engine and exhaust](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_-_engine_and_exhaust_sound_%28YouTube_oMKxhIcSmZs%29.opus).
- Erwin Lindsen — [Lamborghini Aventador SV engine and exhaust](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_SV_-_engine_and_exhaust_sound_%28YouTube_qll6WBfaXvM%29.opus).
- ePic eXhaust — [Lamborghini Aventador SVJ engine and exhaust](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_SVJ_-_engine_and_exhaust_sound_%28YouTube_zqv9zLtHsUM%29.opus).

## Wet road recording (3.0 Preview 50)

`Audio/road-wet.wav` uses 5.50–7.90 seconds from TSP-Talk's roadside recording of a single car passing on wet asphalt near Altenthann, Germany. APEX Lab used the author's public high-quality preview, downmixed the excerpt to mono, band-limited it to 1.25–6.6 kHz and applied gain and a soft peak limit before conversion to 44.1 kHz PCM. Gameplay crossfades the seam and drives level, pitch and stereo position from the simulated wheel spray. [Original recording](https://freesound.org/people/TSP-Talk/sounds/846301/) · [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

## Recorded car body contacts (3.0 Preview 52)

`Audio/body-contact-light.wav` and `Audio/body-contact-firm.wav` use two separate hand strikes on an empty car body recorded by harrisonlace. The excerpts cover 13.802–14.294 s and 7.910–8.478 s of the public HQ preview. APEX Lab downmixed them to mono 44.1 kHz PCM, removed the DC offset, applied common gain and faded the cuts. [Original recording](https://freesound.org/people/harrisonlace/sounds/798843/) · [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
