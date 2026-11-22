import SwiftUI
import CoreGraphics
import AppKit
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers

struct CharacterVoice: Identifiable {
    let id: String
    var name: String
    var voice: String
    var observations: Int
    var speechSeconds: Double
    var ready: Bool
}

@MainActor
final class SubtitleViewModel: ObservableObject {
    @Published var screenshot: NSImage?
    @Published var recognizedText = ""
    @Published var displayedSubtitle = ""
    @Published var translatedText = ""
    let translation = LocalTranslation()
    @Published var translateEnglish = false {
        didSet {
            if !loadingGame {
                silence(reason: "translation_mode_changed"); gate.reset(); translatedText = ""
                saveCurrentGame()
            }
        }
    }
    @Published var region = SubtitleRegion() {
        didSet {
            UserDefaults.standard.set(region.height, forKey: "regionHeight")
            UserDefaults.standard.set(region.bottom, forKey: "regionBottom")
            UserDefaults.standard.set(region.width, forKey: "regionWidth")
            UserDefaults.standard.set(region.ignoreVehiclePlates, forKey: "ignoreVehiclePlates")
            saveCurrentGame()
        }
    }
    @Published var status = "Откройте YouTube в отдельном окне браузера и обновите список окон."
    @Published var windows: [SCWindow] = []
    @Published var selectedWindow: CGWindowID = 0
    @Published var capturing = false
    @Published var busy = false
    @Published var muted = false
    @Published var rate: Double = 1.0 {
        didSet { UserDefaults.standard.set(rate, forKey: "sileroSpeed"); saveCurrentGame() }
    }
    @Published var volume: Double = 1.0 {
        didSet { UserDefaults.standard.set(volume, forKey: "sileroVolume"); saveCurrentGame() }
    }
    @Published var selectedSpeaker = "kseniya" {
        didSet {
            UserDefaults.standard.set(selectedSpeaker, forKey: "sileroSpeaker")
            DiagnosticLog.shared.record("settings.silero_voice", ["speaker": selectedSpeaker])
            saveCurrentGame()
        }
    }
    @Published var autoCharacters = true {
        didSet {
            UserDefaults.standard.set(autoCharacters, forKey: "autoCharacters")
            DiagnosticLog.shared.record("settings.character_detection", ["enabled": autoCharacters])
        }
    }
    @Published var voiceMode = "gender" {
        didSet {
            UserDefaults.standard.set(voiceMode, forKey: "voiceMode"); autoCharacters = voiceMode != "off"
            if !loadingGame { silence(reason: "voice_mode_changed"); gate.reset() }
            saveCurrentGame()
        }
    }
    @Published var maleVoice = "eugene" {
        didSet { UserDefaults.standard.set(maleVoice, forKey: "maleVoice"); saveCurrentGame() }
    }
    @Published var femaleVoice = "kseniya" {
        didSet { UserDefaults.standard.set(femaleVoice, forKey: "femaleVoice"); saveCurrentGame() }
    }
    @Published var nameMaleVoice = "eugene" { didSet { saveCurrentGame() } }
    @Published var nameFemaleVoice = "xenia" { didSet { saveCurrentGame() } }
    @Published var games: [GameProfile] = []
    @Published var gameID = "legacy"
    @Published var gameNameInput = ""
    @Published var gameMessage = ""
    @Published var gameBusy = false
    @Published var nameVoices: [SubtitleNameVoice] = []
    @Published var newSubtitleName = ""
    private var loadingGame = true
    private var gameStorageAvailable = true
    @Published var genderReady = false
    @Published var charactersReady = false
    @Published var characterStatus = "Ожидаю английскую речь"
    @Published var characters: [CharacterVoice] = []
    @Published var newCharacterName = ""
    @Published var training = false
    @Published var trainingStatus = "Добавьте персонажа и запишите несколько образцов его английской речи."
    @Published var characterBusy = false
    private var trainingTask: Task<Void, Never>?
    private var trainingID: UUID?

    private var characterSession = UUID().uuidString
    private var subtitleNameSession = SubtitleNameSession()
    private var routingGeneration = UUID()
    private var routingTask: Task<Void, Never>?
    private var routingID: UUID?
    @Published var engineReady = false
    @Published var engineStatus = "Проверяю Silero…"
    let speakers = [("aidar", "Айдар · мужской"), ("eugene", "Евгений · мужской"),
                    ("kseniya", "Ксения · женский"), ("xenia", "Ксения 2 · женский"), ("baya", "Бая · женский")]
    private let gate = SubtitleGate()
    @Published var speakingText = ""
    @Published var playbackError = ""
    @Published var playbackStatus = "Голос ожидает реплику"
    private let playback = SpeechPlayback()

    init() {
        DiagnosticLog.shared.record("app.ready", ["bundlePath": Bundle.main.bundleURL.path,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "cameraAccess": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "screenAccess": CGPreflightScreenCaptureAccess()])
        captureSource = UserDefaults.standard.string(forKey: "captureSource") ?? "card"
        selectedCardVideo = UserDefaults.standard.string(forKey: "cardVideoID") ?? ""
        selectedCardAudio = UserDefaults.standard.string(forKey: "cardAudioID") ?? ""
        voiceMode = UserDefaults.standard.string(forKey: "voiceMode") ?? "gender"
        if !["gender", "names", "characters", "off"].contains(voiceMode) { voiceMode = "gender" }
        autoCharacters = voiceMode != "off"
        if let value = UserDefaults.standard.string(forKey: "maleVoice"), speakers.contains(where: { $0.0 == value }) { maleVoice = value }
        if let value = UserDefaults.standard.string(forKey: "femaleVoice"), speakers.contains(where: { $0.0 == value }) { femaleVoice = value }
        if let height = UserDefaults.standard.object(forKey: "regionHeight") as? Double,
           let bottom = UserDefaults.standard.object(forKey: "regionBottom") as? Double,
           let width = UserDefaults.standard.object(forKey: "regionWidth") as? Double {
            region = SubtitleRegion(height: min(0.50, max(0.10, height)), bottom: min(0.45, max(0, bottom)), width: min(1, max(0.30, width)))
        }
        if let saved = UserDefaults.standard.object(forKey: "sileroSpeed") as? Double { rate = min(1.20, max(0.85, saved)) }
        if let saved = UserDefaults.standard.object(forKey: "sileroVolume") as? Double { volume = min(1, max(0, saved)) }
        if let saved = UserDefaults.standard.string(forKey: "sileroSpeaker"), speakers.contains(where: { $0.0 == saved }) { selectedSpeaker = saved }
        do {
            if let library = try GameProfileLibrary.load(from: .standard) {
                games = library.games; gameID = library.selectedID
                if let selected = games.first(where: { $0.id == gameID }) { applyGame(selected) }
            } else if UserDefaults.standard.object(forKey: "voiceMode") != nil {
                games = [snapshotGame(id: "legacy", name: "Прежние настройки")]
            } else {
                let preset = try GameProfile.releasePreset()
                games = [preset]; gameID = preset.id; applyGame(preset)
            }
        } catch {
            gameStorageAvailable = false
            gameMessage = "Не удалось прочитать профили игр. Сохранённые данные не изменены."
        }
        loadingGame = false
        saveCurrentGame()
        playback.translator = { [weak self] text in
            guard let self else { throw CancellationError() }
            return try await self.translation.translate(text)
        }
        playback.onTranslation = { [weak self] source, target in
            self?.translatedText = target
            DiagnosticLog.shared.record("translation.ready", ["source": source, "target": target])
        }
        playback.onDiscard = { text in DiagnosticLog.shared.record("subtitle.not_played", ["text": text, "retryPolicy": "explicit_memory_reset"]) }
        playback.onState = { [weak self] state in self?.playbackStatus = state }
        playback.onError = { [weak self] error in self?.playbackError = error }
        playback.onPlaying = { [weak self] text in self?.speakingText = text }
    }

    private func snapshotGame(id: String, name: String) -> GameProfile {
        GameProfile(id: id, name: name, mode: voiceMode, commonVoice: selectedSpeaker,
            maleVoice: maleVoice, femaleVoice: femaleVoice, rate: rate, volume: volume,
            regionHeight: region.height, regionBottom: region.bottom, regionWidth: region.width, names: nameVoices, translateEnglish: translateEnglish, ignoreVehiclePlates: region.ignoreVehiclePlates, nameMaleVoice: nameMaleVoice, nameFemaleVoice: nameFemaleVoice)
    }

    private func applyGame(_ game: GameProfile) {
        loadingGame = true
        voiceMode = game.mode; selectedSpeaker = game.commonVoice
        maleVoice = game.maleVoice; femaleVoice = game.femaleVoice
        nameMaleVoice = game.nameMaleVoice ?? game.maleVoice
        nameFemaleVoice = game.nameFemaleVoice ?? game.femaleVoice
        rate = game.rate; volume = game.volume
        region = SubtitleRegion(height: game.regionHeight, bottom: game.regionBottom, width: game.regionWidth, ignoreVehiclePlates: game.ignoreVehiclePlates ?? true)
        nameVoices = game.names
        if #available(macOS 15.0, *) { translateEnglish = game.translateEnglish ?? false }
        else { translateEnglish = false }
        translatedText = ""
        loadingGame = false
    }

    @discardableResult func saveCurrentGame() -> Bool {
        guard !loadingGame else { return true }
        guard gameStorageAvailable, let index = games.firstIndex(where: { $0.id == gameID }) else { return false }
        var updated = games
        updated[index] = snapshotGame(id: gameID, name: updated[index].name)
        do {
            try GameProfileLibrary(selectedID: gameID, games: updated).save(to: .standard)
            games = updated
            return true
        } catch { gameMessage = "Не удалось сохранить профиль. Проверьте имена и настройки."; return false }
    }

    func selectGame(_ id: String) async {
        guard id != gameID, !gameBusy, !characterBusy, !training,
              let selected = games.first(where: { $0.id == id }), saveCurrentGame() else { return }
        gameBusy = true
        defer { gameBusy = false }
        await stop()
        gameID = id
        applyGame(selected)
        characters = []; characterSession = UUID().uuidString
        newCharacterName = ""; newSubtitleName = ""; gameNameInput = ""
        gate.reset(); recognizedText = ""; displayedSubtitle = ""; playbackError = ""
        characterStatus = "Выбрана игра: \(selected.name)"
        saveCurrentGame()
        if charactersReady {
            do { applyProfiles(try await SileroClient.shared.profiles(game: id)) }
            catch { trainingStatus = error.localizedDescription }
        }
        gameMessage = "Настройки игры загружены. Для продолжения начните захват."
        DiagnosticLog.shared.record("game.selected", ["gameID": id, "name": selected.name, "mode": voiceMode])
    }

    func addGame() async {
        let name = gameNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gameStorageAvailable, !gameBusy, !training, !characterBusy, games.count < 64,
              !name.isEmpty, name.count <= 80 else { gameMessage = "Введите название игры (до 80 символов)."; return }
        guard !games.contains(where: { SubtitleNameRouting.normalized($0.name) == SubtitleNameRouting.normalized(name) }) else {
            gameMessage = "Игра с таким названием уже есть."; return
        }
        guard saveCurrentGame() else { return }
        var game = snapshotGame(id: UUID().uuidString, name: name)
        game.names = []
        games.append(game)
        await selectGame(game.id)
    }

    func renameGame() {
        let name = gameNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !games.contains(where: { $0.id != gameID && SubtitleNameRouting.normalized($0.name) == SubtitleNameRouting.normalized(name) }),
              let index = games.firstIndex(where: { $0.id == gameID }) else { gameMessage = "Введите уникальное название игры."; return }
        games[index].name = name
        if saveCurrentGame() { gameNameInput = ""; gameMessage = "Игра переименована." }
    }

    func addSubtitleName() {
        let name = newSubtitleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, nameVoices.count < 100,
              !nameVoices.contains(where: { SubtitleNameRouting.normalized($0.name) == SubtitleNameRouting.normalized(name) }) else {
            gameMessage = "Введите уникальное имя из субтитров (до 40 символов)."; return
        }
        nameVoices.append(SubtitleNameVoice(name: name, voice: selectedSpeaker))
        if saveCurrentGame() { newSubtitleName = "" }
    }

    func refreshEngine() async {
        let profileGameID = gameID
        engineStatus = "Подготавливаю голоса…"
        do {
            try await LocalRuntime.shared.ensureStarted()
            let health = try await SileroClient.shared.health()
            engineReady = health.ready
            genderReady = health.genderReady ?? false
            if voiceMode == "gender", !genderReady { characterStatus = health.genderError ?? "Модель М/Ж ещё не готова. Проверьте сервис в настройках." }
            charactersReady = (health.speakerIdentificationReady ?? false) && (health.protocolVersion ?? 0) >= 11
            if charactersReady {
                let profiles = try await SileroClient.shared.profiles(game: profileGameID)
                if gameID == profileGameID { applyProfiles(profiles) }
            }
            if !charactersReady { characterStatus = health.speakerIdentificationError ?? "Для различения голосов перезапустите Launch.command." }
            engineStatus = health.englishReady == false
                ? "Русская речь готова. Английская модель недоступна: \(health.englishError ?? "проверьте сборку")"
                : "Silero готов · русский и английский"
            DiagnosticLog.shared.record("silero.ready", ["model": health.model, "pid": health.pid, "speakers": health.speakers])
        } catch {
            engineReady = false
            genderReady = false
            charactersReady = false
            engineStatus = error.localizedDescription
            DiagnosticLog.shared.record("silero.unavailable", ["error": error.localizedDescription])
        }
    }

    func resetMemory() {
        cancelRouting()
        playback.stop(reason: "subtitle_memory_reset")
        gate.reset()
        recognizedText = ""; displayedSubtitle = ""
        status = "Память повторов сброшена. Можно повторно проиграть сцену."
    }

    func previewVoice() {
        DiagnosticLog.shared.record("ui.voice_preview")
        speak("Нам нужно добраться до машины. Осторожно, впереди опасность! Ты готов продолжить?")
    }

    @Published var captureSource = "window" {
        didSet {
            UserDefaults.standard.set(captureSource, forKey: "captureSource")
            resetMemory(); screenshot = nil
        }
    }
    @Published var videoDevices: [CaptureDeviceChoice] = []
    @Published var audioDevices: [CaptureDeviceChoice] = []
    @Published var selectedCardVideo = "" {
        didSet { UserDefaults.standard.set(selectedCardVideo, forKey: "cardVideoID") }
    }
    @Published var selectedCardAudio = "" {
        didSet { UserDefaults.standard.set(selectedCardAudio, forKey: "cardAudioID") }
    }
    var needsSourceAudio: Bool { voiceMode == "gender" || voiceMode == "characters" }
    var sourceReady: Bool { captureSource == "card" ? !selectedCardVideo.isEmpty && (!needsSourceAudio || !selectedCardAudio.isEmpty) : selectedWindow != 0 }
    private var capture: (any SubtitleCapture)?

    func refreshCardDevices(requestPermission: Bool = false) async {
        guard !capturing, !busy else { return }
        busy = true
        defer { busy = false }
        if requestPermission {
            do { try await CardDevices.authorize(.video) }
            catch { status = error.localizedDescription; return }
        }
        videoDevices = CardDevices.choices(.video)
        audioDevices = CardDevices.choices(.audio)
        // Only preselect an explicitly branded capture device, never a webcam.
        if !videoDevices.contains(where: { $0.id == selectedCardVideo }) {
            selectedCardVideo = videoDevices.first(where: { $0.name.localizedCaseInsensitiveContains("AVerMedia") || $0.name.localizedCaseInsensitiveContains("StreamLine") })?.id ?? ""
        }
        if !audioDevices.contains(where: { $0.id == selectedCardAudio }) {
            selectedCardAudio = audioDevices.first(where: { $0.name.localizedCaseInsensitiveContains("AVerMedia") || $0.name.localizedCaseInsensitiveContains("StreamLine") })?.id ?? ""
        }
        DiagnosticLog.shared.record("card.devices", ["videoCount": videoDevices.count, "audioCount": audioDevices.count,
            "cameraAccess": AVCaptureDevice.authorizationStatus(for: .video).rawValue])
        if videoDevices.isEmpty {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted: status = "Нет доступа к видео карты. Разрешите «Камера» для PS Subtitle Voice в настройках macOS."
            case .notDetermined: status = "Нажмите «Обновить устройства», чтобы разрешить доступ к изображению карты."
            default: status = "Видеовход карты не найден. Если звук виден, отключите USB на 10 секунд, подключите заново и обновите устройства."
            }
        } else { status = "Выберите видеовход и звук одной карты. Играйте на телевизоре через HDMI OUT; звук игры остаётся на телевизоре." }
    }
    private var generation = UUID()

    private var screenPermissionRequested = false

    func refreshWindows() async {
        guard !busy, !capturing else { return }
        busy = true
        defer { busy = false }
        if !CGPreflightScreenCaptureAccess() {
            if !screenPermissionRequested {
                screenPermissionRequested = true
                _ = await Task.detached { CGRequestScreenCaptureAccess() }.value
            }
            guard CGPreflightScreenCaptureAccess() else {
                status = "Разрешите запись экрана для установленного PS Subtitle Voice в настройках macOS и один раз перезапустите приложение. Повторные запросы в этом сеансе отключены."
                DiagnosticLog.shared.record("capture.permission_needed", ["bundlePath": Bundle.main.bundleURL.path])
                return
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            windows = content.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 100 && !($0.title ?? "").isEmpty
            }.sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
            if !windows.contains(where: { $0.windowID == selectedWindow }) { selectedWindow = windows.first?.windowID ?? 0 }
            status = windows.isEmpty ? "Окон не найдено. Откройте браузер и обновите список." : "Выберите окно с YouTube. Режим «Театр» помогает убрать лишний текст из области субтитров."
        } catch {
            DiagnosticLog.shared.record("capture.window_list_error", ["error": error.localizedDescription])
            status = "Не удалось получить окна: \(error.localizedDescription). Разрешите запись экрана в настройках конфиденциальности macOS, затем перезапустите приложение."
        }
    }

    func label(_ window: SCWindow) -> String {
        "\(window.owningApplication?.applicationName ?? "Приложение") — \(window.title ?? "Окно")"
    }

    func start() async {
        guard engineReady, !capturing, !busy, sourceReady else { return }
        guard !translateEnglish || translation.ready else { status = "Подготовьте языки в настройках перевода перед захватом."; return }
        busy = true
        generation = UUID()
        let token = generation
        let result: (CGImage, String, String?, Double, Bool, Double) -> Void = { [weak self] image, text, speech, elapsed, nearlyBlack, began in
            Task { @MainActor in
                guard let self, self.generation == token, self.capturing else { return }
                self.screenshot = NSImage(cgImage: image, size: .zero)
                if !text.isEmpty { self.recognizedText = text }
                else if self.region.ignoreVehiclePlates, SubtitleTextFilter.isPlateCode(self.recognizedText) {
                    self.recognizedText = ""
                }
                self.status = elapsed < 0 ? "Подготавливаю распознавание текста… Первый запуск может занять до 45 секунд." : nearlyBlack && text.isEmpty
                    ? (self.captureSource == "card" ? "Чёрный кадр с карты: проверьте HDMI, отключите HDCP на PS5 и установите 1080p60." : "В захвате почти чёрный кадр. Проверьте, видно ли видео в Safari; при необходимости заново выберите окно.")
                    : text.isEmpty ? "Захват работает. Ожидаю субтитры в отмеченной области." : "Захват работает · распознавание \(Int(elapsed * 1000)) мс"
                if let speech {
                    if self.muted { self.gate.release(speech); DiagnosticLog.shared.record("speech.suppressed", ["reason": "muted", "text": speech]) }
                    else if self.training { self.gate.release(speech) }
                    else { self.routeCharacter(speech, began: began) }
                }
            }
        }
        let failure: (String) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.status = "Останавливаю захват: \(message)"
                await self.stop()
                self.status = "Захват остановлен: \(message)"
            }
        }
        let engine: any SubtitleCapture
        if captureSource == "card" {
            engine = CardCapture(region: region, gate: gate, result: result, failure: failure)
        } else {
            engine = WindowCapture(region: region, gate: gate, captureAudio: needsSourceAudio, result: result, failure: failure)
        }
        capture = engine
        do {
            if let card = engine as? CardCapture {
                try await card.start(videoID: selectedCardVideo, audioID: needsSourceAudio ? selectedCardAudio : nil)
            } else if let windowEngine = engine as? WindowCapture,
                      let window = windows.first(where: { $0.windowID == selectedWindow }) {
                try await windowEngine.start(window: window)
            } else { throw CardDevices.error("Выберите доступный источник изображения.") }
            if generation == token {
                capturing = true
                status = captureSource == "card" ? "Карта запущена. Включите игру и субтитры на PS5." : "Захват запущен. Включите видео в выбранном окне."
            } else { await engine.stop() }
        } catch {
            await engine.stop()
            capture = nil
            status = "Не удалось начать захват: \(error.localizedDescription)"
        }
        busy = false
    }

    func stop() async {
        cancelTraining()
        cancelRouting()
        generation = UUID()
        capturing = false
        busy = true
        status = "Останавливаю захват…"
        let engine = capture
        capture = nil
        playback.stop(reason: "capture_stopped")
        await engine?.stop()
        busy = false
        status = "Захват и озвучивание остановлены."
    }

    func openScreenshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        generation = UUID()
        screenshot = image; recognizedText = ""
        status = "Скриншот загружен. Нажмите «Распознать скриншот»."
    }

    func recognizeScreenshot() async {
        guard let image = screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        busy = true
        let area = region
        let token = generation
        let result = await Task.detached(priority: .userInitiated) { Result { try SubtitleRecognition.text(in: image, region: area) } }.value
        guard generation == token else { busy = false; return }
        switch result {
        case .success(let text):
            recognizedText = text
            status = text.isEmpty ? "Текст не найден. Измените область распознавания." : "Текст распознан."
            if !muted { speak(text) }
        case .failure(let error): status = error.localizedDescription
        }
        busy = false
    }

    func speak(_ text: String, automatic: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard engineReady else { if automatic { gate.release(text) }; status = engineStatus; return }
        DiagnosticLog.shared.record("speech.request", ["source": automatic ? "capture" : "manual", "text": text])
        displayedSubtitle = text
        playback.submit(text, speaker: selectedSpeaker, speed: Float(rate), volume: Float(volume), replace: !automatic, translate: translateEnglish)
    }

    func silence(reason: String = "stop_button") {
        if reason != "character_training" { cancelTraining() }
        cancelRouting(); playback.stop(reason: reason)
    }

    private func cancelRouting() {
        subtitleNameSession.reset()
        routingGeneration = UUID()

        routingTask?.cancel(); routingTask = nil; routingID = nil
    }

    private func applyProfiles(_ profiles: [SpeakerIdentity.Profile]) {
        characters = profiles.map { CharacterVoice(id: $0.id, name: $0.name, voice: $0.voice,
            observations: $0.observations, speechSeconds: $0.speechSeconds, ready: $0.ready) }
    }

    func editCharacter(_ action: String, character: CharacterVoice? = nil) async {
        guard !training, !characterBusy else { return }
        let profileGameID = gameID
        characterBusy = true
        defer { characterBusy = false }
        silence(reason: "character_edit")
        do {
            let profiles = try await SileroClient.shared.editCharacter(action: action, id: character?.id ?? "",
                name: character?.name ?? newCharacterName, voice: character?.voice ?? selectedSpeaker, game: profileGameID)
            guard gameID == profileGameID else { return }
            applyProfiles(profiles)
            if action == "add" { newCharacterName = "" }
            trainingStatus = "Сохранено на этом Mac."
            DiagnosticLog.shared.record("speaker.character_edited", ["action": action, "profileID": character?.id ?? ""])
        } catch { trainingStatus = error.localizedDescription }
    }

    func cancelTraining() {
        trainingTask?.cancel(); trainingTask = nil; trainingID = nil
        if training { trainingStatus = "Запись остановлена. Принятые образцы сохранены." }
        training = false
    }

    func train(_ character: CharacterVoice) {
        guard capturing, voiceMode == "characters", charactersReady, !training, let audio = capture?.audio else { return }
        silence(reason: "character_training")
        training = true
        DiagnosticLog.shared.record("speaker.training_started", ["profileID": character.id])
        let id = UUID(); trainingID = id
        let captureToken = generation
        let profileGameID = gameID
        trainingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.trainingID == id { self.training = false; self.trainingTask = nil; self.trainingID = nil } }
            var accepted = 0
            var lastRejection = "Нет чистой речи"
            for part in 1...4 {
                guard !Task.isCancelled, self.generation == captureToken else { return }
                self.trainingStatus = "Запись: \(character.name) · фрагмент \(part)/4. Должен говорить только этот персонаж."
                let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                do { try await Task.sleep(nanoseconds: 3_150_000_000) } catch { return }
                guard !Task.isCancelled, self.generation == captureToken else { return }
                guard let pcm = audio.extract(from: start, through: start + 3) else {
                    lastRejection = "Нет звука выбранного окна. Проверьте воспроизведение."; self.trainingStatus = lastRejection; continue
                }
                do {
                    let profiles = try await SileroClient.shared.enroll(pcm, id: character.id, game: profileGameID)
                    guard !Task.isCancelled, self.generation == captureToken else { return }
                    self.applyProfiles(profiles); accepted += 1
                    DiagnosticLog.shared.record("speaker.training_accepted", ["profileID": character.id, "part": part])
                } catch {
                    lastRejection = error.localizedDescription; self.trainingStatus = lastRejection
                    DiagnosticLog.shared.record("speaker.training_rejected", ["profileID": character.id, "part": part, "reason": lastRejection])
                }
            }
            self.trainingStatus = accepted > 0
                ? "Принято образцов: \(accepted). Для лучшего результата добавьте запись из другой сцены того же персонажа."
                : "Образцы не приняты: " + lastRejection
            self.gate.reset()
        }
    }

    private func routeCharacter(_ text: String, began: Double) {
        if voiceMode == "names" {
            let result = subtitleNameSession.resolve(text, assignments: nameVoices, commonVoice: selectedSpeaker, maleVoice: nameMaleVoice, femaleVoice: nameFemaleVoice)
            let label: String
            switch result.reason {
            case "name_inferred_male": label = "мужской по умолчанию"
            case "name_inferred_female": label = "женский по умолчанию"
            case "unknown_name", "ambiguous_name": label = "общий голос"
            default: label = "голос персонажа"
            }
            characterStatus = result.name.map { "\($0) → \(label)" } ?? "Общий голос"
            DiagnosticLog.shared.record("voice.subtitle_name", ["gameID": gameID, "reason": result.reason, "name": result.name ?? "", "voice": result.voice, "text": result.text])
            displayedSubtitle = result.text
            playback.submit(result.text, speaker: result.voice, speed: Float(rate), volume: Float(volume), translate: translateEnglish)
            return
        }
        guard autoCharacters else { speak(text, automatic: true); return }
        guard voiceMode == "gender" ? genderReady : charactersReady else {
            characterStatus = "Модель анализа не готова: стандартный голос"
            speak(text, automatic: true); return
        }
        let profileGameID = gameID
        let predecessor = routingTask
        let token = routingGeneration
        let captureToken = generation
        let id = UUID()
        let audio = capture?.audio
        routingID = id
        routingTask = Task { [weak self] in
            await predecessor?.value
            guard let self, !Task.isCancelled, self.routingGeneration == token, self.generation == captureToken else { return }
            defer { if self.routingID == id { self.routingTask = nil; self.routingID = nil } }
            let through = began + (self.voiceMode == "gender" ? 2.4 : 2.9)
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let wait = through - now
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(min(wait, 3.1) * 1_000_000_000)) }
            guard !Task.isCancelled, self.routingGeneration == token, self.generation == captureToken, !self.muted else { return }
            guard CMClockGetTime(CMClockGetHostTimeClock()).seconds - began < 8 else {
                DiagnosticLog.shared.record("speaker.routing_expired", ["text": text]); return
            }
            var voice = self.selectedSpeaker
            if let pcm = audio?.extract(from: began - 0.1, through: through) {
                do {
                    if self.voiceMode == "gender" {
                        let result = try await SileroClient.shared.classifyVoice(pcm)
                        guard !Task.isCancelled, self.routingGeneration == token, self.generation == captureToken else { return }
                        if result.label == "male" {
                            voice = self.maleVoice; self.characterStatus = "Мужское звучание → назначенный голос"
                        } else if result.label == "female" {
                            voice = self.femaleVoice; self.characterStatus = "Женское звучание → назначенный голос"
                        } else {
                            self.characterStatus = result.reason == "mixed_voices" ? "Несколько голосов: общий голос"
                                : result.reason == "insufficient_speech" || result.reason == "silence" ? "Мало исходной речи: общий голос"
                                : "М/Ж не определено уверенно: общий голос"
                        }
                        DiagnosticLog.shared.record("voice.classification", ["gameID": profileGameID, "label": result.label ?? "unknown", "score": result.score,
                            "reason": result.reason, "speechSeconds": result.speechSeconds, "analysisMS": result.analysisMS,
                            "audioStart": began - 0.1, "audioEnd": through,
                            "rawLabel": result.rawLabel ?? "unknown", "rawReason": result.rawReason ?? "", "rawScore": result.rawScore ?? 0,
                            "rawSpeechSeconds": result.rawSpeechSeconds ?? 0,
                            "cleanLabel": result.cleanLabel ?? "unknown", "cleanReason": result.cleanReason ?? "", "cleanScore": result.cleanScore ?? 0,
                            "cleanSpeechSeconds": result.cleanSpeechSeconds ?? 0,
                            "enhancement": result.enhancement ?? "unavailable", "enhancementMS": result.enhancementMS ?? 0,
                            "voice": voice, "text": text])
                    } else {
                    let identity = try await SileroClient.shared.identify(pcm, session: self.characterSession, game: profileGameID)
                    guard !Task.isCancelled, self.routingGeneration == token, self.generation == captureToken else { return }
                    self.applyProfiles(identity.profiles)
                    let routedID = identity.profileID
                    if let profile = self.characters.first(where: { $0.id == routedID }) {
                        voice = profile.voice
                        self.characterStatus = "\(profile.name) → \(self.speakers.first(where: { $0.0 == voice })?.1 ?? voice)"
                    } else {
                        self.characterStatus = identity.reason == "no_trained_characters"
                            ? "Сначала запишите образцы персонажей: стандартный голос"
                            : identity.reason == "insufficient_speech" || identity.reason == "silence"
                                ? "Мало исходной речи: стандартный голос"
                                : "Голоса похожи или совпадение слабое: стандартный голос"
                    }
                    DiagnosticLog.shared.record("speaker.decision", ["profileID": identity.profileID ?? "", "score": identity.score,
                        "reason": identity.reason, "speechSeconds": identity.speechSeconds, "analysisMS": identity.analysisMS,
                        "voice": voice, "text": text, "routedProfileID": routedID ?? "",
                        "heldPrevious": false, "matchMargin": identity.margin ?? 0,
                        "profileScores": identity.profileScores ?? [:]])
                    }
                } catch {
                    guard !Task.isCancelled, self.routingGeneration == token, self.generation == captureToken else { return }
                    self.characterStatus = "Не удалось различить голос: используется стандартный"
                    DiagnosticLog.shared.record("speaker.error", ["error": error.localizedDescription])
                }
            } else {
                self.characterStatus = "Недостаточно звука окна: стандартный голос"
                DiagnosticLog.shared.record("speaker.no_audio", ["text": text])
            }
            guard !Task.isCancelled, self.routingGeneration == token, self.generation == captureToken, !self.muted else { return }
            DiagnosticLog.shared.record("speech.request", ["source": "capture", "text": text, "speaker": voice, "automaticCharacter": true])
            self.displayedSubtitle = text
            self.playback.submit(text, speaker: voice, speed: Float(self.rate), volume: Float(self.volume), translate: self.translateEnglish)
        }
    }

    func openLog() {
        DiagnosticLog.shared.record("ui.open_log")
        if let error = DiagnosticLog.shared.flush() { status = "Не удалось записать журнал: " + error; return }
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])
    }

    func markIssue() {
        DiagnosticLog.shared.record("user.issue_marker", ["recognizedText": recognizedText, "speakingText": speakingText,
            "playbackStatus": playbackStatus, "playbackError": playbackError, "captureStatus": status,
            "capturing": capturing, "muted": muted, "speaker": selectedSpeaker, "rate": rate])
        status = "Сбой отмечен в журнале."
    }

    func permissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

struct ContentView: View {
    @StateObject private var model = SubtitleViewModel()
    @AppStorage(InterfaceLanguage.key) private var interfaceLanguage = "ru"
    @State private var settingsOpen = false
    @State private var regionOpen = false
    @State private var settingsTab = "voices"
    private let accent = Color(red: 0.46, green: 0.39, blue: 0.91)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    subtitleCard
                    HStack(spacing: 12) {
                        Circle().fill(model.capturing ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(InterfaceLanguage.text(compactStatus)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 20) {
                    sourceCard
                    playbackCard
                    Spacer(minLength: 0)
                    HStack(spacing: 7) {
                        Image(systemName: model.engineReady ? "checkmark.shield" : "exclamationmark.circle")
                        Text(InterfaceLanguage.text(model.engineReady ? "Локальная обработка" : "Подготовка голосов…")).lineLimit(3)
                    }.font(.caption).foregroundStyle(model.engineReady ? Color.secondary : Color.orange)
                }.frame(width: 290)
            }.padding(24)
        }
        .id(interfaceLanguage)
        .background {
            if #available(macOS 15.0, *) { LocalTranslationHost(engine: model.translation) }
        }
        .onReceive(model.translation.$request) { request in
            if let request, request.text == nil { settingsOpen = false }
        }
        .onChange(of: model.translateEnglish) { enabled in
            if enabled, !model.translation.ready { model.translation.prepare() }
        }
        .onAppear { if model.translateEnglish { model.translation.prepare() } }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .environment(\.locale, Locale(identifier: interfaceLanguage))
        .frame(minWidth: 1020, minHeight: 680)
        .disabled(model.gameBusy)
        .background(MovableWindow(isPresented: $settingsOpen, title: InterfaceLanguage.text("Настройки"), size: NSSize(width: 760, height: 560), content: settings.environment(\.locale, Locale(identifier: interfaceLanguage)), onClose: { model.saveCurrentGame() }).frame(width: 0, height: 0))
        .background(MovableWindow(isPresented: $regionOpen, title: InterfaceLanguage.text("Область субтитров"), size: NSSize(width: 440, height: 400), content: regionSettings.environment(\.locale, Locale(identifier: interfaceLanguage)).frame(width: 440, height: 400).tint(accent), onClose: { model.saveCurrentGame() }).frame(width: 0, height: 0))
        .task { await model.refreshEngine(); if model.captureSource == "card" { await model.refreshCardDevices() } }
        .onReceive(NotificationCenter.default.publisher(for: .AVCaptureDeviceWasConnected)) { _ in
            if model.captureSource == "card" { Task { await model.refreshCardDevices() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.silence(reason: "app_termination")
            DiagnosticLog.shared.record("session.end"); DiagnosticLog.shared.flush()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSApplication.shared.applicationIconImage).resizable().frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("PS Subtitle Voice").font(.system(size: 19, weight: .semibold, design: .rounded))
                Text(InterfaceLanguage.text("Игра звучит по-русски")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(InterfaceLanguage.text("Игра"), selection: Binding(get: { model.gameID }, set: { id in Task { await model.selectGame(id) } })) {
                ForEach(model.games) { game in Text(game.name).tag(game.id) }
            }.frame(width: 240).disabled(model.busy || model.training || model.characterBusy)
            Button { settingsOpen = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                .help(InterfaceLanguage.text("Настройки игры и озвучивания"))
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.94)
                if let image = model.screenshot {
                    let ratio = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        if regionOpen {
                            Rectangle().fill(accent.opacity(0.12)).overlay(Rectangle().strokeBorder(accent.opacity(0.8), lineWidth: 1))
                                .frame(width: size.width * model.region.width, height: size.height * model.region.height)
                                .offset(x: size.width * (1 - model.region.width) / 2, y: size.height * (1 - model.region.bottom - model.region.height))
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: model.captureSource == "card" ? "tv" : "macwindow").font(.system(size: 36, weight: .light))
                        Text(InterfaceLanguage.text(model.captureSource == "card" ? "Изображение с PS5" : "Изображение из окна")).font(.headline)
                        Text(InterfaceLanguage.text("Выберите источник и начните захват")).font(.callout).foregroundStyle(.gray)
                    }.foregroundStyle(.white.opacity(0.75))
                }
                VStack {
                    HStack {
                        Label(InterfaceLanguage.text(model.captureSource == "card" ? "PS5 · HDMI" : "Захват окна"), systemImage: model.captureSource == "card" ? "cable.connector" : "macwindow")
                            .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.65), in: Capsule())
                        Spacer()
                        if model.capturing { Label(InterfaceLanguage.text("Захват"), systemImage: "circle.fill").font(.caption).foregroundStyle(.green).padding(8).background(.black.opacity(0.65), in: Capsule()) }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Button { regionOpen = true } label: { Label(InterfaceLanguage.text("Область субтитров"), systemImage: "viewfinder") }
                            .buttonStyle(.bordered).tint(.white).controlSize(.small)
                    }
                }.padding(14).foregroundStyle(.white)
            }
        }.frame(minHeight: 280, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var compactStatus: String {
        if model.busy { return "Подготовка…" }
        if !model.engineReady { return model.engineStatus }
        if ["Не удалось", "Захват остановлен:", "Чёрный кадр", "почти чёрный", "Подготовьте языки", "Первый запуск"].contains(where: model.status.contains) { return model.status }
        if model.capturing { return model.muted ? "Захват работает · озвучивание выключено" : "Готово к озвучиванию" }
        return "Выберите источник и начните захват"
    }

    private var subtitleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(InterfaceLanguage.text("СУБТИТРЫ")).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                if !model.speakingText.isEmpty { Label(InterfaceLanguage.text("Озвучивание"), systemImage: "waveform").font(.caption).foregroundStyle(accent) }
            }
            Text(subtitleText.isEmpty ? InterfaceLanguage.text("Здесь появится реплика") : subtitleText)
                .font(.system(size: 17)).foregroundStyle(subtitleText.isEmpty ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading).lineLimit(4).textSelection(.enabled)
            if !model.playbackError.isEmpty { Text(InterfaceLanguage.text(model.playbackError)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var subtitleText: String {
        model.speakingText.isEmpty ? model.displayedSubtitle : model.speakingText
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(InterfaceLanguage.text("Источник")).font(.headline)
            Picker(InterfaceLanguage.text("Источник"), selection: $model.captureSource) {
                Text(InterfaceLanguage.text("PS5 / карта")).tag("card")
                Text(InterfaceLanguage.text("Окно")).tag("window")
            }.pickerStyle(.segmented).labelsHidden().disabled(model.capturing || model.busy)
                .onChange(of: model.captureSource) { source in if source == "card" { Task { await model.refreshCardDevices(requestPermission: true) } } }
            if model.captureSource == "card" {
                Picker(InterfaceLanguage.text("Видео"), selection: $model.selectedCardVideo) {
                    Text(InterfaceLanguage.text("Выберите карту")).tag("")
                    ForEach(model.videoDevices) { Text($0.name).tag($0.id) }
                }.disabled(model.capturing || model.busy)
                Picker(InterfaceLanguage.text("Звук"), selection: $model.selectedCardAudio) {
                    Text(InterfaceLanguage.text("Не выбран")).tag("")
                    ForEach(model.audioDevices) { Text($0.name).tag($0.id) }
                }.disabled(model.capturing || model.busy)
                Button { Task { await model.refreshCardDevices(requestPermission: true) } } label: { Label(InterfaceLanguage.text("Обновить устройства"), systemImage: "arrow.clockwise") }
                    .buttonStyle(.link).font(.caption).disabled(model.capturing || model.busy)
            } else {
                Picker(InterfaceLanguage.text("Окно"), selection: $model.selectedWindow) {
                    Text(InterfaceLanguage.text("Выберите окно")).tag(CGWindowID(0))
                    ForEach(model.windows, id: \.windowID) { Text(model.label($0)).tag($0.windowID) }
                }.disabled(model.capturing || model.busy)
                HStack {
                    Button(InterfaceLanguage.text("Обновить")) { Task { await model.refreshWindows() } }.disabled(model.capturing || model.busy)
                    Button { model.permissionSettings() } label: { Image(systemName: "lock.shield") }.help(InterfaceLanguage.text("Разрешение на запись экрана"))
                }.controlSize(.small)
            }
            Button {
                Task { if model.capturing { await model.stop() } else { await model.start() } }
            } label: {
                Label(InterfaceLanguage.text(model.capturing ? "Остановить захват" : "Начать захват"), systemImage: model.capturing ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.busy || (!model.capturing && (!model.sourceReady || !model.engineReady)))
            if model.busy { ProgressView().controlSize(.small) }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(InterfaceLanguage.text("Озвучивание")).font(.headline)
            Text(InterfaceLanguage.text(modeTitle)).font(.callout).foregroundStyle(.secondary)
            HStack {
                Image(systemName: model.muted ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1).help(InterfaceLanguage.text("Громкость озвучивания"))
                Text("\(Int(model.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34)
            }
            Toggle(InterfaceLanguage.text("Озвучивать"), isOn: Binding(get: { !model.muted }, set: { enabled in
                model.muted = !enabled
                DiagnosticLog.shared.record("settings.muted", ["muted": !enabled])
                if !enabled { model.silence(reason: "muted") }
            })).toggleStyle(.switch)
            HStack {
                Button(InterfaceLanguage.text("Прервать речь")) { model.silence() }
                Button { model.resetMemory() } label: { Label(InterfaceLanguage.text("После перемотки"), systemImage: "arrow.counterclockwise") }.help(InterfaceLanguage.text("Сбросить повторы и текущего персонажа после перемотки"))
            }.controlSize(.small)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var modeTitle: String {
        switch model.voiceMode {
        case "gender": return "Мужской / женский голос"
        case "names": return "По именам в субтитрах"
        case "characters": return "Обученные персонажи"
        default: return "Один общий голос"
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(InterfaceLanguage.text("Настройки")).font(.title2.weight(.semibold))
                    Text(model.games.first(where: { $0.id == model.gameID })?.name ?? "Профиль игры").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(InterfaceLanguage.text("Готово")) { model.saveCurrentGame(); settingsOpen = false }.keyboardShortcut(.defaultAction)
            }.padding(22)
            HStack {
                Picker(InterfaceLanguage.text("Язык интерфейса"), selection: $interfaceLanguage) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer()
            }.padding(.horizontal, 22).padding(.bottom, 12)
            TabView(selection: $settingsTab) {
                ScrollView { VStack(alignment: .leading, spacing: 18) { voiceSettings }.padding(22) }
                    .tabItem { Label(InterfaceLanguage.text("Голоса"), systemImage: "waveform") }.tag("voices")
                VStack(spacing: 18) {
                    Image(systemName: "viewfinder").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(InterfaceLanguage.text("Настройка рядом с предпросмотром")).font(.headline)
                    Text(InterfaceLanguage.text("Область настраивается в отдельном небольшом окне. Его можно переместить, чтобы видеть рамку на изображении."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button(InterfaceLanguage.text("Открыть настройку области")) { settingsOpen = false; regionOpen = true }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tabItem { Label(InterfaceLanguage.text("Область"), systemImage: "viewfinder") }.tag("region")
                gameSettings.tabItem { Label(InterfaceLanguage.text("Игры"), systemImage: "gamecontroller") }.tag("games")
                serviceSettings.tabItem { Label(InterfaceLanguage.text("Сервис"), systemImage: "wrench.and.screwdriver") }.tag("service")
            }.padding(.horizontal, 14).padding(.bottom, 14)
        }.frame(width: 760, height: 560).tint(accent).id(interfaceLanguage)
    }

    @ViewBuilder private var voiceSettings: some View {
            TranslationSettings(model: model, engine: model.translation)
            Divider()
            HStack {
                Picker(InterfaceLanguage.text("Общий голос"), selection: $model.selectedSpeaker) {
                    ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                }
                Button(InterfaceLanguage.text("Прослушать")) { model.previewVoice() }.disabled(!model.engineReady || model.muted)
            }
            HStack {
                Picker(InterfaceLanguage.text("Выбор голоса"), selection: $model.voiceMode) {
                    Text(InterfaceLanguage.text("Мужской / женский")).tag("gender")
                    Text(InterfaceLanguage.text("По именам в субтитрах")).tag("names")
                    Text(InterfaceLanguage.text("Обученные персонажи")).tag("characters")
                    Text(InterfaceLanguage.text("Один общий голос")).tag("off")
                }.disabled(model.capturing || model.training)

                if model.voiceMode != "off" { Text(InterfaceLanguage.text(model.characterStatus)).font(.caption).foregroundStyle(.secondary) }
            }
            if model.voiceMode == "gender" {
                HStack {
                    Picker(InterfaceLanguage.text("Мужской"), selection: $model.maleVoice) {
                        ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                    }
                    Picker(InterfaceLanguage.text("Женский"), selection: $model.femaleVoice) {
                        ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                    }
                }
                Text(InterfaceLanguage.text(model.genderReady ? "Обучение не требуется. При сомнении или нескольких голосах звучит общий голос." : "Модель М/Ж недоступна. Откройте вкладку «Сервис» и нажмите «Проверить»."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.voiceMode == "names" {
                HStack {
                    Picker(InterfaceLanguage.text("Мужской по умолчанию"), selection: $model.nameMaleVoice) {
                        ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                    }
                    Picker(InterfaceLanguage.text("Женский по умолчанию"), selection: $model.nameFemaleVoice) {
                        ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                    }
                }.disabled(model.capturing || model.training)
                Text(InterfaceLanguage.text("Для имён вне списка пол определяется локально по словарю имён и обращений. Неоднозначные имена и неизвестные прозвища используют общий голос. Продолжение без имени сохраняет предыдущий голос."))
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    HStack {
                        TextField(InterfaceLanguage.text("Имя точно как в субтитрах"), text: $model.newSubtitleName)
                        Button(InterfaceLanguage.text("Добавить имя")) { model.addSubtitleName() }
                    }
                    Text(InterfaceLanguage.text("Выберите общий голос перед добавлением или измените голос в строке ниже. Поддерживаются «Имя: реплика» и «[Имя] реплика». Назначения в списке имеют приоритет. Имя персонажа не произносится.")).font(.caption).foregroundStyle(.secondary)
                    ForEach($model.nameVoices) { $entry in
                        HStack {
                            TextField(InterfaceLanguage.text("Имя"), text: $entry.name).onSubmit { model.saveCurrentGame() }
                            Picker(InterfaceLanguage.text("Голос"), selection: $entry.voice) {
                                ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                            }.onChange(of: entry.voice) { _ in model.saveCurrentGame() }
                            Button(InterfaceLanguage.text("Убрать")) { model.nameVoices.removeAll { $0.id == entry.id }; model.saveCurrentGame() }
                        }
                    }
                }.disabled(model.capturing || model.training)
            }
            if model.voiceMode == "characters" {
            DisclosureGroup(InterfaceLanguage.text("Обучение персонажам") + " (\(model.characters.count))") {
                HStack {
                    TextField(InterfaceLanguage.text("Имя нового персонажа"), text: $model.newCharacterName)
                    Button(InterfaceLanguage.text("Добавить персонажа")) { Task { await model.editCharacter("add") } }
                        .disabled(model.newCharacterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.charactersReady || model.training || model.characterBusy)
                }
                Text(InterfaceLanguage.text("Выберите голос выше перед добавлением. Запустите захват, включите сцену с одним говорящим и нажмите «Записать 12 секунд». Во время обучения озвучка молчит. Образцы сохраняются локально без аудиозаписей."))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    ForEach($model.characters) { $character in
                        VStack(alignment: .leading) {
                            HStack {
                                TextField(InterfaceLanguage.text("Имя"), text: $character.name).frame(maxWidth: 180)
                                    .onSubmit { Task { await model.editCharacter("update", character: character) } }
                                Picker(InterfaceLanguage.text("Голос"), selection: $character.voice) {
                                    ForEach(model.speakers, id: \.0) { speaker in Text(InterfaceLanguage.text(speaker.1)).tag(speaker.0) }
                                }.onChange(of: character.voice) { _ in Task { await model.editCharacter("update", character: character) } }
                            }.disabled(model.training || model.characterBusy)
                            HStack {
                                Button(InterfaceLanguage.text("Записать 12 секунд")) { model.train(character) }
                                    .disabled(!model.capturing || !model.autoCharacters)
                                Button(InterfaceLanguage.text("Очистить обучение")) { Task { await model.editCharacter("clear", character: character) } }
                                Button(InterfaceLanguage.text("Удалить")) { Task { await model.editCharacter("delete", character: character) } }
                            }.disabled(model.training || model.characterBusy)
                            Text(String(format: InterfaceLanguage.text("%@ · образцов: %d · речи: %.1f с"), InterfaceLanguage.text(character.ready ? "Готов к узнаванию" : "Нужно минимум 2 образца и 4 секунды речи"), character.observations, character.speechSeconds)).font(.caption)
                        }
                    }
                }.frame(maxHeight: 160)
                HStack {
                    Text(InterfaceLanguage.text(model.trainingStatus)).font(.caption).textSelection(.enabled)
                    if model.training { Button(InterfaceLanguage.text("Остановить запись")) { model.cancelTraining() } }
                }
            }
            }
            Divider()
            HStack {
                Text(String(format: InterfaceLanguage.text("Скорость ×%.2f"), model.rate)).frame(width: 120, alignment: .leading)
                Slider(value: $model.rate, in: 0.85...1.20)
            }
            Text(InterfaceLanguage.text("Следующая речь готовится заранее. Неуверенные определения используют общий голос.")).font(.caption).foregroundStyle(.secondary)
    }

    private var regionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(InterfaceLanguage.text("Область распознавания")).font(.headline)
            Text(InterfaceLanguage.text("Переместите это окно рядом с изображением. Для изменения рамки остановите захват.")).font(.caption).foregroundStyle(.secondary)
            Group {
                regionSlider("Высота", value: $model.region.height, range: 0.10...0.50)
                regionSlider("Отступ снизу", value: $model.region.bottom, range: 0...0.45)
                regionSlider("Ширина", value: $model.region.width, range: 0.30...1)
            }.disabled(model.capturing || model.busy)
            Toggle(InterfaceLanguage.text("Фильтровать надписи на объектах"), isOn: $model.region.ignoreVehiclePlates)
                .font(.callout).disabled(model.capturing || model.busy)
                .help(InterfaceLanguage.text("Исключать номера, мелкие метки и отдельные надписи над субтитрами. Сохраняется для выбранной игры."))
            HStack {
                Button(InterfaceLanguage.text("Остановить захват")) { Task { await model.stop() } }.disabled(!model.capturing)
                Spacer()
                Button(InterfaceLanguage.text("Готово")) { model.saveCurrentGame(); regionOpen = false }
            }
            Text(InterfaceLanguage.text("При переходе с YouTube на HDMI расположение субтитров может отличаться.")).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20)
    }

    private var gameSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(InterfaceLanguage.text("Профили игр")).font(.headline)
            Text(InterfaceLanguage.text("Для каждой игры сохраняются голоса, режим, область субтитров, скорость, громкость и обучение.")).foregroundStyle(.secondary)
            Picker(InterfaceLanguage.text("Игра"), selection: Binding(get: { model.gameID }, set: { id in Task { await model.selectGame(id) } })) {
                ForEach(model.games) { Text($0.name).tag($0.id) }
            }
            TextField(InterfaceLanguage.text("Название игры"), text: $model.gameNameInput)
            HStack {
                Button(InterfaceLanguage.text("Добавить игру")) { Task { await model.addGame() } }
                Button(InterfaceLanguage.text("Переименовать выбранную")) { model.renameGame() }
            }
            if !model.gameMessage.isEmpty { Text(InterfaceLanguage.text(model.gameMessage)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }.padding(24).disabled(model.busy || model.training || model.characterBusy || model.gameBusy)
    }

    private var serviceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(InterfaceLanguage.text("Локальная обработка")).font(.headline)
            Text(InterfaceLanguage.text(model.engineStatus)).foregroundStyle(model.engineReady ? Color.secondary : Color.orange).textSelection(.enabled)
            HStack {
                Button(InterfaceLanguage.text("Проверить")) { Task { await model.refreshEngine() } }
                Button(InterfaceLanguage.text("Открыть журнал")) { model.openLog() }
                Button(InterfaceLanguage.text("Отметить сбой")) { model.markIssue() }
            }
            Divider()
            DisclosureGroup(InterfaceLanguage.text("Диагностика")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(InterfaceLanguage.text(model.status))
                    Text(InterfaceLanguage.text(model.playbackStatus))
                    Text(model.recognizedText.isEmpty ? "Текст пока не распознан" : model.recognizedText)
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(InterfaceLanguage.text("Проверка скриншота")).font(.headline)
            HStack {
                Button(InterfaceLanguage.text("Открыть скриншот")) { model.openScreenshot() }.disabled(model.capturing || model.busy)
                Button(InterfaceLanguage.text("Распознать")) { Task { await model.recognizeScreenshot() } }.disabled(model.capturing || model.busy || model.screenshot == nil)
            }
            TextEditor(text: $model.recognizedText).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            Button(InterfaceLanguage.text("Произнести текст")) { model.speak(model.recognizedText) }.disabled(model.recognizedText.isEmpty || model.muted || !model.engineReady)
            Text(InterfaceLanguage.text("PS Subtitle Voice · 1.2.0\nРазработано при участии OpenAI Codex.\nМодели и обработка работают на Mac."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(24)
    }

    private func regionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(InterfaceLanguage.text(title)).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 45)
        }
    }
}


private struct TranslationSettings: View {
    @ObservedObject var model: SubtitleViewModel
    @ObservedObject var engine: LocalTranslation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(InterfaceLanguage.text("Переводить английские субтитры на русский"), isOn: $model.translateEnglish)
                .disabled(model.capturing || model.training || !supported)
            Text(InterfaceLanguage.text("Сохраняется для выбранной игры. Русский текст читается как прежде. При первом включении macOS предложит загрузить языки; затем перевод работает без интернета."))
                .font(.caption).foregroundStyle(.secondary)
            if model.translateEnglish {
                HStack {
                    Text(InterfaceLanguage.text(engine.status)).font(.caption).foregroundStyle(engine.ready ? Color.secondary : Color.orange)
                    Spacer()
                    Button(InterfaceLanguage.text("Подготовить языки")) { engine.prepare() }.disabled(engine.request != nil || model.capturing)
                }
            }
            if !supported { Text(InterfaceLanguage.text("Для локального перевода нужна macOS 15 или новее.")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var supported: Bool { if #available(macOS 15.0, *) { return true }; return false }
}
