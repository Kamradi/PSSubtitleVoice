"""Stage a source-only public tree; never include user profiles, logs or weights."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('destination', type=Path)
a = p.parse_args()
dest = a.destination.resolve()
if dest.exists():
    raise SystemExit('Choose an empty destination; existing files are never deleted.')
dest.mkdir(parents=True)

def ignore(directory, names):
    return [n for n in names if n in {'.DS_Store', '__pycache__', 'xcuserdata'} or n.endswith('.xcuserstate')]

for name in ['PSSubtitleVoice', 'PSSubtitleVoice.xcodeproj', 'Scripts', 'docs', 'Licenses']:
    shutil.copytree(ROOT / name, dest / name, ignore=ignore)
for name in ['README.md', 'README_RU.md', 'README_EN.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md',
             'PSSubtitleVoice.entitlements', 'PSSubtitleVoice-Info.plist', 'sample_subtitles.png']:
    shutil.copy2(ROOT / name, dest / name)
(dest / 'Runtime').mkdir()
for file in (ROOT / 'Runtime').iterdir():
    if file.is_file() and (file.suffix in {'.py', '.sha256', '.command'} or file.name in {'requirements.txt', 'requirements-lock.txt'} or file.name.endswith('LICENSE.txt')):
        shutil.copy2(file, dest / 'Runtime' / file.name)
shutil.copytree(ROOT / 'Runtime/OCRWorker', dest / 'Runtime/OCRWorker')
(dest / 'Distribution').mkdir()
for name in ['BuildRelease.py', 'Python.entitlements']:
    shutil.copy2(ROOT / 'Distribution' / name, dest / 'Distribution' / name)
# Replay tools need private user logs and are not part of the public test suite.
(dest / 'Checks').mkdir()
for folder in (ROOT / 'Checks').iterdir():
    if folder.is_dir() and not folder.name.startswith('Replay'):
        shutil.copytree(folder, dest / 'Checks' / folder.name, ignore=ignore)
shutil.copy2(ROOT / 'Checks/main.swift', dest / 'Checks/main.swift')
pbx = dest / 'PSSubtitleVoice.xcodeproj/project.pbxproj'
source = pbx.read_text()
import re
source = re.sub(r'DEVELOPMENT_TEAM = [A-Z0-9]+;', 'DEVELOPMENT_TEAM = "";', source)
source = source.replace('CODE_SIGN_IDENTITY = "Apple Development";', 'CODE_SIGN_IDENTITY = "-";')
pbx.write_text(source)
(dest / '.gitignore').write_text('''build/
DerivedData/
Distribution/*.app/
Distribution/*.dmg
Distribution/*.sha256
Runtime/.venv/
Runtime/gender-model/
Runtime/*.pt
Runtime/*.onnx
Runtime/*.zip
Runtime/*.partial
Runtime/*.log
Runtime/*.json
Runtime/.launch.lock
**/__pycache__/
*.pyc
.DS_Store
xcuserdata/
*.xcuserstate
*.p12
*.mobileprovision
.env
''')
for file in dest.rglob('*'):
    if file.is_file() and file.suffix in {'.swift', '.py', '.md', '.command', '.pbxproj', '.json'}:
        content = file.read_text()
        if (chr(47) + 'Users' + chr(47)) in content:
            raise SystemExit('Private local path found in: ' + str(file.relative_to(dest)))
print('Public source tree staged and checked.')
