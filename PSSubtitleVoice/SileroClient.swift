import Foundation

struct SileroHealth: Decodable {
    let ready: Bool
    let model: String
    let speakers: [String]
    let pid: Int
    let speakerIdentificationReady: Bool?
    let speakerIdentificationError: String?
    let protocolVersion: Int?
    let genderReady: Bool?
    let genderError: String?
    let englishReady: Bool?
    let englishError: String?
}
struct SileroAudio: Decodable {
    let wav: String
    let duration: Double
    let synthesisSeconds: Double
    let speaker: String
}

struct SpeakerIdentity: Decodable {
    struct Profile: Decodable { let id: String; let name: String; let voice: String; let observations: Int; let speechSeconds: Double; let ready: Bool }
    let registryID: String
    let profileID: String?
    let score: Double
    let reason: String
    let speechSeconds: Double
    let analysisMS: Int
    let profiles: [Profile]
    let margin: Double?
    let profileScores: [String: Double]?
}

struct VoiceClassification: Decodable {
    let label: String?
    let score: Double
    let reason: String
    let speechSeconds: Double
    let analysisMS: Int
    let rawLabel: String?
    let rawReason: String?
    let rawScore: Double?
    let rawSpeechSeconds: Double?
    let cleanLabel: String?
    let cleanReason: String?
    let cleanScore: Double?
    let cleanSpeechSeconds: Double?
    let enhancement: String?
    let enhancementMS: Int?
}

actor SileroClient {
    static let shared = SileroClient()
    private struct State: Decodable { let port: Int; let token: String }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = ProcessInfo.processInfo.environment["PS_SUBTITLE_SILERO_STATE_FILE"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("PSSubtitleVoice/Silero/service.json")
        guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: url)),
              (1...65535).contains(state.port) else {
            throw NSError(domain: "Silero", code: 1, userInfo: [NSLocalizedDescriptionKey: "Движок озвучивания ещё не запущен. Нажмите «Проверить» в настройках сервиса."])
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(state.port)/\(path)")!)
        if path == "identify-speaker" || path == "classify-voice" { request.timeoutInterval = 3 }
        request.setValue("Bearer " + state.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let message = detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? detail! : "Silero не смог обработать запрос (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(path))."
            throw NSError(domain: "Silero", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }

    func classifyVoice(_ audio: Data) async throws -> VoiceClassification {
        try await JSONDecoder().decode(VoiceClassification.self, from: request("classify-voice", body: ["pcm": audio.base64EncodedString()]))
    }

    func identify(_ audio: Data, session: String, game: String = "legacy") async throws -> SpeakerIdentity {
        try await JSONDecoder().decode(SpeakerIdentity.self, from: request("identify-speaker", body: ["pcm": audio.base64EncodedString(), "session": session, "game": game]))
    }

    private struct Profiles: Decodable { let profiles: [SpeakerIdentity.Profile] }
    func profiles(game: String = "legacy") async throws -> [SpeakerIdentity.Profile] {
        try JSONDecoder().decode(Profiles.self, from: await request("characters?game=" + game)).profiles
    }
    func editCharacter(action: String, id: String = "", name: String = "", voice: String = "eugene", game: String = "legacy") async throws -> [SpeakerIdentity.Profile] {
        try JSONDecoder().decode(Profiles.self, from: await request("characters", body: ["action": action, "id": id, "name": name, "voice": voice, "game": game])).profiles
    }
    func enroll(_ audio: Data, id: String, game: String = "legacy") async throws -> [SpeakerIdentity.Profile] {
        try JSONDecoder().decode(Profiles.self, from: await request("enroll-speaker", body: ["pcm": audio.base64EncodedString(), "id": id, "session": "enrollment", "game": game])).profiles
    }

    func health() async throws -> SileroHealth {
        try await JSONDecoder().decode(SileroHealth.self, from: request("health"))
    }
    func shutdown() async throws {
        _ = try await request("shutdown", body: [:])
    }

    func synthesize(_ text: String, speaker: String) async throws -> (data: Data, seconds: Double, duration: Double) {
        let result = try await JSONDecoder().decode(SileroAudio.self, from: request("synthesize", body: ["text": text, "speaker": speaker]))
        guard let audio = Data(base64Encoded: result.wav), audio.count > 44, result.duration > 0 else {
            throw NSError(domain: "Silero", code: 3, userInfo: [NSLocalizedDescriptionKey: "Silero вернул пустую запись."])
        }
        return (audio, result.synthesisSeconds, result.duration)
    }
}
