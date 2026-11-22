"""Install the GTCRN ONNX export from the official sherpa-onnx release."""
import hashlib
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent
URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/gtcrn_simple.onnx'
SHA256 = 'e77603ac0c23dac3227dd2d7135b3a585cbee2679048aecfa886657d3ae1b534'

def install():
    path = ROOT / 'gtcrn_simple.onnx'
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != SHA256:
        temporary = path.with_suffix('.onnx.partial')
        urllib.request.urlretrieve(URL, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
            raise ValueError('GTCRN checksum mismatch')
        temporary.replace(path)
    (ROOT / 'speech-enhancer.sha256').write_text(SHA256 + '  gtcrn_simple.onnx\n')
    print('Local GTCRN speech enhancement ready.')

if __name__ == '__main__': install()
