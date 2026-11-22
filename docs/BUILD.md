# Build from source / Сборка из исходников

[User guide (English)](../README_EN.md) · [Инструкция пользователя](../README_RU.md)

## English

The Xcode project builds the SwiftUI application, while the release packager adds the Python runtime, model files and isolated OCR helper. Building only the Xcode target produces a UI without the bundled speech runtime. End users should use the DMG from Releases.

### Tools

- Apple Silicon Mac; Xcode 26 or newer with Command Line Tools and the macOS SDK.
- Python **3.12** for the relocatable runtime layout used by this release.
- Network access to install dependencies and download official model weights. Models and `.venv` are intentionally excluded from Git.
- Several GB of free disk space for the virtual environment and app bundle.

### Build

```sh
git clone https://github.com/Kamradi/PSSubtitleVoice.git
cd PSSubtitleVoice
PS_SUBTITLE_PYTHON=python3.12 ./Runtime/setup.command
./Scripts/build.command
open 'Distribution/PS Subtitle Voice.app'
```

`Runtime/setup.command` downloads official Silero, VAD, speaker, gender and enhancement models. The installers and `*.sha256` files document model sources and checksums. Direct dependency versions are pinned in `Runtime/requirements.txt`; `requirements-lock.txt` records the development environment. The build script uses an **ad-hoc signature** by default, not a private developer identity. Set `SSV_SIGNING_IDENTITY` to your own installed signing identity if desired. Keep the same bundle identifier and signing identity across your local updates to reduce permission resets.

`Distribution/BuildRelease.py` copies the base interpreter referenced by `.venv/pyvenv.cfg`, adds installed packages, compiles `Runtime/OCRWorker/main.swift`, signs Python and the helper with inherited sandbox entitlements, then signs and verifies the app. It preserves an existing output by moving it to a timestamped backup. Review the script when using a Python distribution with a different filesystem layout.

The app still targets macOS 13; newer framework calls are guarded. Translation requires macOS 15 at runtime. Distribution is arm64 only.

### Validate

```sh
./Scripts/check.command
```

Checks cover subtitle stability/duplicates, name routing and persistence, object-text filtering, OCR-worker behavior and Python service logic. Internal replay checks use private diagnostic logs and are not shipped in the public source tree. Hardware capture, system permissions and language downloading also require a real Mac and manual verification.

### Create a DMG

Make a clean staging directory containing the finished app and a symlink named `Applications` pointing to `/Applications`. Include the guides and third-party notices, then run:

```sh
hdiutil create -volname 'PS Subtitle Voice' -srcfolder build/Installer \
  -format UDZO -imagekey zlib-level=6 Distribution/PSSubtitleVoice-1.2.1-macOS-arm64.dmg
hdiutil verify Distribution/PSSubtitleVoice-1.2.1-macOS-arm64.dmg
shasum -a 256 Distribution/PSSubtitleVoice-1.2.1-macOS-arm64.dmg
```

Notarization and Developer ID distribution are not configured. No signing credentials, service tokens, user logs, hardware serials or enrolled speaker data should be committed or packaged.

### Architecture

| Area | Files |
| --- | --- |
| SwiftUI interface, settings and routing orchestration | `PSSubtitleVoice/ContentView.swift` |
| Native capture | `CardCapture.swift`, `WindowCapture.swift`, `CaptureFrameWorker.swift` |
| Isolated Vision OCR | `SubtitleRecognition.swift`, `OCRProcess.swift`, `Runtime/OCRWorker/main.swift` |
| Bounded synthesis/playback queue | `SpeechPlayback.swift` |
| Profiles and offline name inference | `GameProfile.swift`, `DefaultGame.json` |
| Apple offline translation | `LocalTranslation.swift` |
| Local authenticated speech service | `Runtime/silero_service.py`, `LocalRuntime.swift`, `SileroClient.swift` |
| Source audio classification/enrollment | `Runtime/gender_classifier.py`, `speaker_identifier.py`, `enrolled_voices.py` |

## Русский

Xcode собирает интерфейс SwiftUI. Скрипт упаковки добавляет Python, зависимости, модели и отдельный OCR-процесс. Сборка только Xcode-цели не содержит готового движка речи. Для обычного использования скачайте DMG.

Потребуются **Mac с Apple Silicon, Xcode 26+ и Python 3.12**, сеть для первоначальной загрузки моделей и несколько гигабайт свободного места. Команды сборки и проверок приведены выше. Готовое приложение появится в `Distribution/PS Subtitle Voice.app`.

`Runtime/setup.command` создаёт виртуальное окружение и загружает официальные модели. Их источники и контрольные суммы указаны в установщиках и SHA-256-манифестах. Скрипт сборки по умолчанию использует **ad-hoc подпись**. Для своей подписи задайте переменную `SSV_SIGNING_IDENTITY`; сертификаты и ключи в репозиторий не добавляются.

`Distribution/BuildRelease.py` берёт базовый интерпретатор из `.venv/pyvenv.cfg`, копирует пакеты, компилирует OCR-помощник и подписывает дочерние процессы с наследуемой песочницей. Существующая готовая сборка сохраняется в резервную папку с датой. Для нестандартного расположения Python проверьте пути в этом скрипте.

Проверки покрывают повторы и стабильность OCR, имена, профили, фильтрацию, отдельный OCR-процесс и логику Python-службы. Внутренние проверки воспроизведения журналов требуют частных входных файлов и не включаются в публичные исходники. Физическая карта, выдача разрешений и загрузка языков проверяются на настоящем Mac.

Для DMG создайте чистую папку `build/Installer`, положите туда приложение, инструкции, уведомления о лицензиях и ссылку `Applications → /Applications`, затем выполните команды `hdiutil` выше. Нотарификация Apple не настроена. Не включайте локальные журналы, токены, серийные номера устройств, голосовые образцы и свои ключи подписи в исходники или образ.

## Contributions / Изменения

Keep source capture, OCR, voice selection and playback independently cancellable. A stale OCR or synthesis result must never restart a stopped session. Add regressions for observed misses or duplicates while preserving numbers, negations and genuinely new dialogue.

Захват, OCR, выбор голоса и воспроизведение должны отменяться независимо. Устаревший результат не должен возобновлять остановленную сессию. Проверяйте исправления повторов вместе с числами, отрицаниями и новыми репликами.
