"""Install the official audEERING six-layer ONNX model without importing remote code."""
from pathlib import Path
import hashlib
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
URL = 'https://zenodo.org/records/7761387/files/w2v2-L-robust-6-age-gender.25c844af-1.1.1.zip'

ARCHIVE_SHA256 = 'ee6b1a69aef08f2f6fdd8e91aa88cc055aab97288b3bbd5dfa4a4997c94fe17f'

def install():
    destination = ROOT / 'gender-model'
    if (destination / 'model.onnx').exists() and (destination / 'model.yaml').exists():
        print('Local M/F model is installed.')
        return
    archive = ROOT / 'gender-model.zip'
    if not archive.exists():
        temporary = ROOT / 'gender-model.zip.partial'
        print('Downloading official audEERING M/F model (317 MB)...', flush=True)
        urllib.request.urlretrieve(URL, temporary)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError('Gender model archive checksum mismatch')
    with zipfile.ZipFile(archive) as source:
        required = ['model.onnx', 'model.yaml']
        if not all(name in source.namelist() for name in required):
            raise ValueError('Unexpected official model archive layout')
        destination.mkdir(exist_ok=True)
        for name in required:
            temporary = destination / (name + '.partial')
            with source.open(name) as incoming, temporary.open('wb') as output:
                import shutil
                shutil.copyfileobj(incoming, output)
            temporary.replace(destination / name)
    sums = []
    for path in (archive, destination / 'model.onnx', destination / 'model.yaml'):
        sums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + str(path.relative_to(ROOT)))
    (ROOT / 'gender-model.sha256').write_text('\n'.join(sums) + '\n')
    print('Local M/F model installed.')

if __name__ == '__main__': install()
