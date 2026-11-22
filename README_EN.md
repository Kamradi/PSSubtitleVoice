# PS Subtitle Voice — English user guide

[Русский](README_RU.md) · [Overview](README.md) · [Download](https://github.com/Kamradi/PSSubtitleVoice/releases/latest)

PS Subtitle Voice reads visible game subtitles aloud on a Mac. Capture a PS5 through a USB HDMI capture card, or capture a browser window containing game footage. Silero synthesis runs locally. No software is installed on the console.

The interface supports **English and Russian**. Open Settings using the top-right button and choose **English** in the language selector. The choice is saved and applies immediately, including utility windows. This guide includes Russian labels for users switching from Russian. Interface language does not change subtitle recognition, narration language or game profiles.

## 1. Requirements

- An Apple Silicon Mac. Primary testing was on M4; this repository does not provide a ready-made Intel or Windows release.
- macOS 13 or newer for capture and narration; macOS 15 or newer for local translation.
- PS5 capture: a macOS-compatible USB capture card, two HDMI cables and an appropriate USB connection. Tested hardware: AVerMedia StreamLine Mini+ GC311G2.
- Window capture: a browser/player showing visible Russian or English subtitles.
- The downloadable app includes Python, dependencies and models. End users do not need Xcode or a separate Python installation. See [BUILD.md](docs/BUILD.md) for source builds.

## 2. Install and launch

1. Download `PSSubtitleVoice-1.2.0-macOS-arm64.dmg` from [Releases](https://github.com/Kamradi/PSSubtitleVoice/releases/latest).
2. Open the DMG and drag **PS Subtitle Voice.app** to **Applications**.
3. Eject the DMG. Launch the copy in **Applications**.
4. The public release is ad-hoc signed and **not notarized by Apple**. If macOS blocks the first launch, try Finder's contextual **Open** action. If that is unavailable, use **System Settings → Privacy & Security → Open Anyway**, then confirm. Availability depends on your Mac's policy. You do not need to disable Gatekeeper globally.
5. Wait for the voices to initialize. Initial OCR setup may take up to 45 seconds; later recognition is faster.
6. Grant access for your chosen source. If macOS asks to quit and reopen the app, do so once.

For updates, quit the old app, replace it in Applications and reopen it. Profiles live in the macOS app container, not inside the app bundle. A change in signing identity may cause macOS to ask for capture permissions again.

## 3. Connect a PS5

```text
PS5 HDMI OUT → capture card HDMI IN
capture card HDMI OUT → TV / monitor
capture card USB → Mac
```

1. Disable **HDCP** in PS5 settings for game capture. Protected streaming applications may not work with HDCP disabled.
2. Start with **1080p at 60 Hz**. HDMI passthrough and USB capture capabilities depend on your card.
3. Enable in-game subtitles. For name-based voices, also enable speaker names if supported by the game.
4. Select **PS5 / карта** (PS5 / card). Select the card under **Видео** (Video), and its HDMI audio device under **Звук** (Audio).
5. Allow **Camera** access for the card's video input and **Microphone** access for its HDMI audio input. The built-in camera and microphone are not automatically used as gameplay sources.
6. Click **Начать захват** (Start capture). Play on the TV using the card's HDMI OUT. Narration uses the Mac's current system audio output; game audio stays on the TV.

If you change USB ports, click **Обновить устройства** (Refresh devices) and check both selected inputs. Reconnecting hardware may change its video device identifier.

## 4. Capture YouTube or another window

1. Open game footage with visible Russian or English subtitles. Burned-in subtitles and visible subtitle overlays work.
2. Select **Окно** (Window), then the browser window.
3. Click **Обновить** (Refresh) if it is missing.
4. Grant **Screen & System Audio Recording** access in macOS Privacy & Security. The section name varies by macOS version.
5. Browser theater mode helps keep comments and page controls outside the OCR region. Recheck the region after resizing the window or video.
6. Click **Начать захват**.

DRM-protected video may produce black frames. Audio-based speaker selection needs source audio that macOS can capture. Name-based routing uses subtitle text instead.

## 5. Set the subtitle region

Click **Область субтитров** (Subtitle region) in the preview. A movable utility window opens and the OCR region appears over the image. Stop capture using the button in that window before changing the sliders.

- **Высота**: region height.
- **Отступ снизу**: distance from the bottom of the image.
- **Ширина**: centered region width.

Include both subtitle lines and the speaker label. Avoid minimaps, license plates, interaction prompts and counters. **Фильтровать надписи на объектах** (Filter text on objects) reduces unrelated text; it is heuristic and cannot remove every HUD element. If real subtitles disappear, check the region and try disabling the filter.

The region overlay disappears when its settings window closes. Each game keeps its own region.

## 6. Voices and characters

Open the settings button at the top right → **Голоса** (Voices). Stop capture before changing routing mode or character assignments.

| Mode | Behavior |
| --- | --- |
| **По именам в субтитрах** | Exact configured speaker name, then offline name/title inference, then the common voice. |
| **Мужской / женский** | Analyze source audio; uncertain decisions use the common voice. |
| **Обученные персонажи** | Experimental comparison with enrolled source-audio examples. |
| **Один общий голос** | Use one common voice for every line. |

Available Russian Silero voices: Aidar (`aidar`), Eugene (`eugene`), Kseniya (`kseniya`), Xenia / “Ксения 2” (`xenia`), Baya (`baya`). These are synthesized voices, not the original actors. This release does not include RVC or voice cloning.

### Name-based routing

Supported labels include `Лусия: Dialogue` and `[Лусия] Dialogue`.

1. Enter the exact subtitle name and click **Добавить имя** (Add name).
2. Choose a voice in that character's row. Explicit assignments override inference.
3. Choose **Мужской по умолчанию** (Default male), **Женский по умолчанию** (Default female) and **Общий голос** (Common voice).
4. Names not in your list are checked against an offline Russian/English name and title lexicon. Ambiguous names such as “Саша”, and unknown nicknames, use the common voice.
5. The speaker label is removed before narration. An unnamed continuation keeps the previous speaker's voice until a new explicit name or a context reset.

Add an exact assignment when a character is consistently misclassified. If OCR changes the spelling, check subtitle size and the capture region. The lexicon cannot reliably classify every fictional name.

### Enrolled characters

Enrollment identifies a source speaker; it does **not** train a new TTS voice. Add a character, select an existing voice and capture clean examples using **Записать 12 секунд** (Record 12 seconds). At least two accepted examples and four seconds of speech are required. Music, overlapping voices and noise may cause rejection. Narration pauses during enrollment. Silero still generates the output voice.

## 7. Included “ГТА 6” preset

New installations start with this preset. Updates do not overwrite existing profiles.

| Setting | Value |
| --- | --- |
| Mode | Name-based routing |
| Common voice | Baya |
| Default male / female | Aidar / Baya |
| Лусия / Джейсон | Xenia / Eugene |
| Местный житель, Охранник, Продавец, Водитель, Турист | Aidar |
| Местная жительница, Охранница, Продавщица, Туристка | Baya |
| Speed | ×1.10185 |
| Narration volume | 49.07% |
| Height / bottom offset / width | 21% / 2% / 46% of the frame |
| Object-text filter | Enabled |
| English → Russian | Enabled on macOS 15+; language preparation is required |

Check this region against your own footage. In **Настройки → Игры** (Settings → Games), add separate game profiles. Hardware-specific USB identifiers are not part of the preset; devices are selected on each Mac.

## 8. Translation and mixed-language speech

In **Настройки → Голоса**, enable **Переводить английские субтитры на русский** (Translate English subtitles to Russian), then click **Подготовить языки** (Prepare languages). macOS downloads the language data on first use; translation then runs locally. With translation enabled, capture waits until the languages are ready. On macOS 13–14 translation is unavailable and is automatically disabled for the starter profile.

Russian subtitles do not need translation. Without translation, English words/names use the English Silero model. Numbers are prepared for Russian pronunciation. Apple translation quality varies for slang, names and mixed-language sentences.

## 9. Everyday controls

- **Озвучивать** (Narrate): enable/disable narration while retaining capture.
- Volume slider: narration level, independently of TV volume.
- **Прервать речь** (Interrupt speech): stop the current line and pending queue.
- **После перемотки** (After seeking): clear spoken-line memory and speaker context. Use after replaying a scene or repeating a dialogue.
- **Остановить захват** (Stop capture): stop capture and narration.

The queue is bounded to avoid reading old dialogue long after it disappears. If subtitles arrive faster than speech can finish, stale lines may be skipped. A modest speed increase may help.

## 10. Troubleshooting

| Symptom | Check |
| --- | --- |
| No capture card | USB connection, adapter and power; reconnect, then refresh devices. Audio may enumerate before video. |
| Black image | PS5 power, correct HDMI IN/OUT, disabled HDCP and a supported signal; start with 1080p60. |
| Repeated permission prompts | Launch the same Applications copy. Remove an obsolete app entry from the relevant Privacy & Security list, add the current app, and reopen when requested. |
| No recognized dialogue | In-game subtitles, region placement, contrast and font size. |
| Silent after seeking backward | Click **После перемотки**; spoken lines remain remembered until reset. |
| Wrong voice | Check the exact speaker label and assignment. An unrecognized name uses the common voice. |
| Narrating unrelated text | Narrow the OCR region, enable object-text filtering and exclude HUD elements. |
| Skipped or repeated line | **Настройки → Сервис → Отметить сбой** (Mark issue), then **Открыть журнал** (Open log). Record the line and approximate time. |
| No sound | Narration switch, app volume, Mac system audio output; then **Сервис → Проверить** (Service → Check). |

**Сервис → Диагностика** (Service → Diagnostics) shows raw OCR text and technical status. Logs stay local, rotating across up to four files of roughly 2 MB each. They may contain dialogue and window names; review before sharing in GitHub Issues.

## 11. Source, licenses and development

Application code is [MIT](LICENSE). Model and dependency licenses are [listed separately](THIRD_PARTY_NOTICES.md). Silero and audEERING weights have noncommercial conditions and are not relicensed as MIT. The app bundle includes model/dependency notices.

**Developed with assistance from OpenAI Codex** — prototyping, implementation, debugging and documentation. OpenAI APIs are not used during application operation. This is an independent project, not affiliated with Sony, PlayStation or Rockstar Games.
