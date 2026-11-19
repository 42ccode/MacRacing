"""Build and verify a portable archive, then retain only the current release."""
import plistlib
from pathlib import Path
from tempfile import TemporaryDirectory
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
        out.write(validation,f'{root}/VALIDATION.md')
        for sample in sorted((base/'Docs'/f'Audio-{release}').glob('*.wav')):
            out.write(sample,f'{root}/{sample.name}')
        credits = base/'Docs'/f'Driving-{release}'/'README.md'
        if credits.exists():
            out.write(credits,f'{root}/实机截图/README.md')
        for f in sorted((base/'Docs'/f'Driving-{release}').glob('*')):
            if f.suffix.lower() not in {'.jpg', '.png'}:
                continue
            out.write(f,f'{root}/实机截图/{f.name}')
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
