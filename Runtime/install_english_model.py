"""Install the official Silero v3 English model with a pinned checksum."""
from pathlib import Path
import hashlib
import urllib.request

ROOT = Path(__file__).resolve().parent
URL = 'https://models.silero.ai/models/tts/en/v3_en.pt'
SHA256 = '02b71034d9f13bc4001195017bac9db1c6bb6115e03fea52983e8abcff13b665'

def install():
    target = ROOT / 'v3_en.pt'
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != SHA256:
        temporary = target.with_suffix('.pt.partial')
        urllib.request.urlretrieve(URL, temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
            raise ValueError('English model checksum mismatch')
        temporary.replace(target)
    (ROOT / 'english-model.sha256').write_text(SHA256 + '  v3_en.pt\n')
    print('Local English Silero model ready.')

if __name__ == '__main__': install()
