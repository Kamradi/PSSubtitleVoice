"""Build a relocatable, offline Apple Silicon app for this Mac. Run after xcodebuild Release."""
from pathlib import Path
import shutil
import subprocess
import sys
import os
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
SIGNING_IDENTITY = os.environ.get('SSV_SIGNING_IDENTITY', '-')
APP = ROOT / 'Distribution/PS Subtitle Voice.app'
SOURCE = ROOT / 'build/Build/Products/Release/PSSubtitleVoice.app'
configuration = dict(line.split(' = ', 1) for line in (ROOT / 'Runtime/.venv/pyvenv.cfg').read_text().splitlines() if ' = ' in line)
PYTHON = Path(configuration['home']).parent
# Staging lives only inside Distribution; never remove a user's installed app.
if APP.exists():
    backup = APP.with_name('PS Subtitle Voice.previous-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.app')
    if backup.exists():
        raise SystemExit('A previous release backup already exists; choose a new staging folder.')
    APP.rename(backup)
shutil.copytree(SOURCE, APP, symlinks=True)
resources = APP / 'Contents/Resources'
resources.mkdir(exist_ok=True)
shutil.copy2(ROOT / 'PSSubtitleVoice/AppIcon.icns', resources / 'AppIcon.icns')

def ignore(path, names):
    skipped = {'__pycache__', 'site-packages', 'test', 'tests', 'idlelib', 'ensurepip'}
    return [n for n in names if n in skipped or n.endswith('.pyc')]

shutil.copytree(PYTHON, resources / 'Python', symlinks=True, ignore=ignore)
shutil.copytree(ROOT / 'Runtime/.venv/lib/python3.12/site-packages', resources / 'Python/lib/python3.12/site-packages',
                symlinks=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
# Relocate the upstream runtime's absolute documentation/pkg-config links.
for link in (resources / 'Python').rglob('*'):
    if link.is_symlink() and link.readlink().is_absolute():
        replacement = link.with_name(link.readlink().name)
        if not replacement.exists(): raise RuntimeError('Unresolved runtime link: ' + str(link))
        target = replacement.name
        link.unlink(); link.symlink_to(target)

runtime = resources / 'Runtime'; runtime.mkdir()
for path in (ROOT / 'Runtime').iterdir():
    if path.is_file() and (path.suffix in ('.py', '.onnx', '.pt', '.sha256') or path.name.endswith('LICENSE.txt')):
        if not path.name.startswith(('test_', 'check_')): shutil.copy2(path, runtime / path.name)
shutil.copytree(ROOT / 'Runtime/gender-model', runtime / 'gender-model')
for name in ('README.md', 'README_RU.md', 'README_EN.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md'):
    shutil.copy2(ROOT / name, resources / name)
shutil.copytree(ROOT / 'Licenses', resources / 'Licenses', dirs_exist_ok=True)
helpers = resources / 'Helpers'; helpers.mkdir(exist_ok=True)
subprocess.run(['xcrun', 'swiftc', '-O', '-target', 'arm64-apple-macos13.0', str(ROOT / 'PSSubtitleVoice/DiagnosticLog.swift'), str(ROOT / 'PSSubtitleVoice/SubtitleRecognition.swift'), str(ROOT / 'Runtime/OCRWorker/main.swift'), '-o', str(helpers / 'PSSubtitleOCR')], check=True)
helper_entitlements = ROOT / 'Distribution/Python.entitlements'
helper_entitlements.write_text('''<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.inherit</key><true/></dict></plist>''')
subprocess.run(['codesign', '--force', '--sign', SIGNING_IDENTITY, '--entitlements', str(helper_entitlements), str(resources / 'Python/bin/python3.12')], check=True)
subprocess.run(['codesign', '--force', '--sign', SIGNING_IDENTITY, '--entitlements', str(helper_entitlements), str(helpers / 'PSSubtitleOCR')], check=True)
subprocess.run(['codesign', '--force', '--sign', SIGNING_IDENTITY, '--entitlements', str(ROOT / 'PSSubtitleVoice.entitlements'), str(APP)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(APP)], check=True)
print(APP)
