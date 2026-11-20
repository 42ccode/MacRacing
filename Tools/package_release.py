"""Build and verify a portable archive, then retain only the current release."""
import hashlib
import json
import plistlib
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import quote
import wave
from zipfile import ZipFile, ZIP_DEFLATED

base = Path(__file__).resolve().parents[1]
app = base / 'dist' / 'APEX Lab.app'
metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
version = metadata['CFBundleShortVersionString']
release = '.'.join(version.split('.')[:2])
archive_version = version if version.split('.')[-1] != '0' else release
if stage := metadata.get('APEXReleaseStage'):
    archive_version = f'{archive_version}-{stage}'
root = f'APEX-Lab-{archive_version}'
archive = base/'dist'/f'{root}-arm64.zip'
asset_dir = app/'Contents/Resources/Assets'
manifest_path = asset_dir/'SHA256SUMS.json'
manifest = json.loads(manifest_path.read_bytes())
files = {p.relative_to(asset_dir).as_posix(): p for p in asset_dir.rglob('*')
         if p.is_file() and p != manifest_path and not any(part.startswith('.') for part in p.relative_to(asset_dir).parts)}
if files.keys() != manifest.keys():
    raise ValueError(f'Bundled files differ from the asset manifest: {sorted(files.keys() ^ manifest.keys())}')
for name, path in files.items():
    if hashlib.sha256(path.read_bytes()).hexdigest() != manifest[name]:
        raise ValueError(f'Bundled asset failed SHA-256 verification: {name}')

audio_dir = base/'Docs'/'Audio-3.0'
samples = (audio_dir/'Porsche911-audio.wav', audio_dir/'Centenario-audio.wav')
for sample in samples:
    with wave.open(str(sample), 'rb') as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getnframes(), source.getcomptype()) != (
               2, 2, 44100, 8 * 44100, 'NONE'):
            raise ValueError(f'{sample.name} must be eight seconds of 44.1 kHz stereo PCM16')
        if len(source.readframes(8 * 44100)) != 8 * 44100 * 4:
            raise ValueError(f'Incomplete audio sample: {sample.name}')

screenshots = ('preview55-two-car-garage.jpg', 'preview55-porsche-cockpit.jpg', 'preview55-porsche-mirror.jpg',
               'preview55-centenario-cockpit.jpg', 'preview55-centenario-showroom.jpg', 'preview56-porsche-steering.jpg',
               'preview57-porsche-braking.jpg', 'preview57-centenario-braking.jpg', 'preview57-narrow-mirrors.jpg',
               'preview58-porsche-dashboard.jpg')
gallery = base/'Docs'/'Driving-3.0'
app_assets = f'{quote(app.name)}/Contents/Resources/Assets'
caption = f'''# APEX Lab 实机画面

- [两车选车页](preview55-two-car-garage.jpg) 截自 Preview 55 实机界面。
- [Porsche 911 Carrera 4S 驾驶舱](preview55-porsche-cockpit.jpg) 和 [驾驶位右侧后视镜](preview55-porsche-mirror.jpg) 截自湿地河谷环线。
- [Lamborghini Centenario 驾驶舱](preview55-centenario-cockpit.jpg) 截自湿地河谷环线，[展厅开门画面](preview55-centenario-showroom.jpg) 可观察剪刀门和内饰。

- [911 方向盘转角对照](preview56-porsche-steering.jpg) 展示 Preview 56 按源模型校准后的旋转轴。
- [911 北环制动曲线](preview57-porsche-braking.jpg) 与 [Centenario 北环制动曲线](preview57-centenario-braking.jpg) 展示同一弯道两种模拟驾驶节奏。
- [双车左后视镜对照](preview57-narrow-mirrors.jpg) 展示 42° 视野下的驾驶位。
- [911 弯中仪表台对照](preview58-porsche-dashboard.jpg) 展示低座高右转头时的原车表皮。

两款车辆模型和改编预览均按 CC BY 4.0 提供。Porsche 模型由 JK3Dstudios 制作，Centenario 模型由 SDC PERFORMANCE™️ 制作。模型来源和改编细节见 [车辆资源说明](../{app_assets}/Vehicles/README.md) 及 [第三方素材署名](../THIRD-PARTY-NOTICES.md)。
'''

with TemporaryDirectory(prefix='.apex-package-', dir=archive.parent) as temporary:
    pending = Path(temporary)/archive.name
    with ZipFile(pending, 'w', compression=ZIP_DEFLATED, compresslevel=5) as out:
        for f in sorted(app.rglob('*')):
            if f.is_file() and not any(x.startswith('.') for x in f.relative_to(app).parts):
                out.write(f, f'{root}/{app.name}/{f.relative_to(app)}')
        out.write(base/'Docs/试玩说明.md',f'{root}/试玩说明.md')
        validation = base/'Docs'/f'VALIDATION-{archive_version}.md'
        if not validation.exists():
            validation = base/'Docs'/f'VALIDATION-{release}.md'
        notes = validation.read_text(encoding='utf-8')
        notes = notes.replace(f'](Audio-{release}/', '](')
        notes = notes.replace(f'](Driving-{release}/', '](实机截图/')
        notes = notes.replace('](../Assets/THIRD-PARTY-NOTICES.md)', '](THIRD-PARTY-NOTICES.md)')
        notes = notes.replace('](../Assets/', f']({quote(app.name)}/Contents/Resources/Assets/')
        out.writestr(f'{root}/VALIDATION.md', notes)
        for sample in samples:
            out.write(sample,f'{root}/{sample.name}')
        notice = (asset_dir/'THIRD-PARTY-NOTICES.md').read_text(encoding='utf-8')
        notice = notice.replace('](Vehicles/',f']({app_assets}/Vehicles/')
        out.writestr(f'{root}/THIRD-PARTY-NOTICES.md',notice)
        out.writestr(f'{root}/实机截图/README.md',caption)
        for name in screenshots:
            out.write(gallery/name,f'{root}/实机截图/{name}')
    with ZipFile(pending) as out:
        if damaged := out.testzip():
            raise RuntimeError(f'Archive checksum failed: {damaged}')
        exe = out.getinfo(f'{root}/{app.name}/Contents/MacOS/APEXLab')
        if not exe.external_attr >> 16 & 0o111:
            raise RuntimeError('Archived application executable lacks execution permission')
    pending.replace(archive)

removed = 0
for previous in sorted(archive.parent.glob('APEX-Lab-*-arm64.zip')):
    if previous != archive and previous.is_file() and not previous.is_symlink():
        previous.unlink()
        removed += 1
print(archive, f'{archive.stat().st_size/2**20:.1f} MiB')
print(f'Removed {removed} previous release archive(s)')
