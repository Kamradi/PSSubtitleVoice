import Foundation

struct SubtitleNameVoice: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var voice: String
}

struct GameProfile: Codable, Identifiable {
    var id: String
    var name: String
    var mode = "gender"
    var commonVoice = "kseniya"
    var maleVoice = "eugene"
    var femaleVoice = "kseniya"
    var rate = 1.0
    var volume = 1.0
    var regionHeight = 0.30
    var regionBottom = 0.0
    var regionWidth = 0.92
    var names: [SubtitleNameVoice] = []
    // Optional for backward-compatible decoding of existing profiles.
    var translateEnglish: Bool? = nil
    var ignoreVehiclePlates: Bool? = nil
    var nameMaleVoice: String? = nil
    var nameFemaleVoice: String? = nil
}

extension GameProfile {
    static func releasePreset() throws -> GameProfile {
        guard let url = Bundle.main.url(forResource: "DefaultGame", withExtension: "json") else {
            throw NSError(domain: "GameProfiles", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не найден профиль релиза."])
        }
        return try releasePreset(data: Data(contentsOf: url))
    }

    static func releasePreset(data: Data) throws -> GameProfile {
        let game = try JSONDecoder().decode(GameProfile.self, from: data)
        try GameProfileLibrary(selectedID: game.id, games: [game]).validate()
        return game
    }
}

struct GameProfileLibrary: Codable {
    var version = 1
    var selectedID: String
    var games: [GameProfile]
    static let key = "gameProfiles.v1"
    static let voices: Set<String> = ["aidar", "eugene", "kseniya", "xenia", "baya"]

    func validate() throws {
        guard version == 1, !games.isEmpty, games.count <= 64,
              Set(games.map(\.id)).count == games.count,
              games.contains(where: { $0.id == selectedID }) else { throw invalid() }
        for game in games {
            guard game.id == "legacy" || UUID(uuidString: game.id) != nil,
                  !game.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, game.name.count <= 80,
                  ["gender", "names", "characters", "off"].contains(game.mode),
                  [game.commonVoice, game.maleVoice, game.femaleVoice].allSatisfy(Self.voices.contains),
                  [game.nameMaleVoice, game.nameFemaleVoice].compactMap({ $0 }).allSatisfy(Self.voices.contains),
                  game.rate.isFinite, (0.85...1.20).contains(game.rate),
                  game.volume.isFinite, (0...1).contains(game.volume),
                  (0.10...0.50).contains(game.regionHeight), (0...0.45).contains(game.regionBottom),
                  (0.30...1).contains(game.regionWidth), game.names.count <= 100,
                  game.names.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 && Self.voices.contains($0.voice) })
            else { throw invalid() }
        }
    }
    private func invalid() -> NSError {
        NSError(domain: "GameProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать настройки игр. Сохранённые данные не изменены."])
    }
    func save(to defaults: UserDefaults) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
    static func load(from defaults: UserDefaults) throws -> Self? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate()
        return library
    }
}

/// Speaker context belongs to one capture session, never to persisted game settings.
struct SubtitleNameSession {
    private var previous: SubtitleNameRouting?

    mutating func reset() { previous = nil }

    mutating func resolve(_ text: String, assignments: [SubtitleNameVoice], commonVoice: String, maleVoice: String? = nil, femaleVoice: String? = nil) -> SubtitleNameRouting {
        let result = SubtitleNameRouting.resolve(text, assignments: assignments, commonVoice: commonVoice, maleVoice: maleVoice, femaleVoice: femaleVoice)
        if result.reason == "missing_name", let previous {
            return SubtitleNameRouting(text: result.text, voice: previous.voice, name: previous.name, reason: "name_continuation")
        }
        // Any explicit speaker replaces the previous context, including an inferred voice.
        // A mixed block cannot establish a single speaker for the following line.
        previous = result.reason == "multiple_names" ? nil : result
        return result
    }
}

struct SubtitleNameRouting {
    let text: String
    let voice: String
    let name: String?
    let reason: String

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    static func resolve(_ text: String, assignments: [SubtitleNameVoice], commonVoice: String, maleVoice: String? = nil, femaleVoice: String? = nil) -> Self {
        // Infer only from an explicit speaker label, never from dialogue words.
        let expression = try! NSRegularExpression(pattern: "^\\s*[-–—]?\\s*(?:\\[([^\\]]{1,40})\\]\\s*:?|([\\p{L}][\\p{L}\\p{M}0-9 _'’.-]{0,39}):)\\s*(.+)$", options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return Self(text: text, voice: commonVoice, name: nil, reason: "missing_name")
        }
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        let name = ns.substring(with: range)
        let body = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = assignments.filter { normalized($0.name) == normalized(name) }
        // OCR can join two speaker lines. Do not assign the entire block to the first.
        if assignments.contains(where: { entry in
            let escaped = NSRegularExpression.escapedPattern(for: entry.name.trimmingCharacters(in: .whitespacesAndNewlines))
            return body.range(of: "(?:^|\\s)(?:\\[" + escaped + "\\]\\s*:?|" + escaped + "\\s*:)", options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            return Self(text: text, voice: commonVoice, name: nil, reason: "multiple_names")
        }
        if matches.count == 1 {
            return Self(text: body, voice: matches[0].voice, name: matches[0].name, reason: "named_match")
        }
        if matches.isEmpty {
            switch SubtitleNameGender.infer(name) {
            case .male where maleVoice != nil:
                return Self(text: body, voice: maleVoice!, name: name, reason: "name_inferred_male")
            case .female where femaleVoice != nil:
                return Self(text: body, voice: femaleVoice!, name: name, reason: "name_inferred_female")
            default: break
            }
        }
        return Self(text: body, voice: commonVoice, name: name, reason: matches.isEmpty ? "unknown_name" : "ambiguous_name")
    }
}

/// Conservative offline inference. Ambiguous names and unknown nicknames stay
/// on the common voice; explicit game assignments always take precedence.
enum SubtitleNameGender {
    enum Gender { case male, female }
    private static let male = Set("""
    александр алексей андрей антон артем артур борис вадим валентин валерий василий виктор виталий владимир владислав вячеслав геннадий георгий григорий даниил денис дмитрий евгений егор иван игорь илья кирилл константин лев леонид макар максим матвей михаил никита николай олег павел петр роман руслан семен сергей станислав степан тимофей федор юрий ярослав
    джейсон джоэл джон джек джеймс майкл майк тревер франклин том томас дэвид давид данк донни дэнни денни данни danny кэл брайан генри ник нэйтан вито джо леон крис кристофер роберт боб серджио карл карлос луис льюис мигель хосе педро рик ричард марк маркус бен бенджамин уильям билл билли эрик джош джошуа дэн дэниел даниэль итан
    paul peter john jack james michael mike jason joel brian henry nick nathan leon chris robert bob tom thomas david daniel william ben franklin trevor carlos miguel jose pedro victor rick richard mark marcus ethan
    продавец охранник водитель турист полицейский мужчина парень солдат капитан бармен официант доктор шериф
    """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let female = Set("""
    александра алена алина алиса алла анастасия анна валентина валерия варвара вера виктория галина дарья диана евгения екатерина елена елизавета жанна зинаида злата инна ирина карина ксения лариса лидия любовь людмила маргарита марина мария милана надежда наталья нина оксана олеся ольга полина раиса регина светлана софия софья тамара татьяна ульяна юлия яна
    линда моника лиза лиз бетти барбара нэнси карен дона донна хелен хлоя стейси кристина кристен лусия люсия вики викки элли эллен эбби абби джилл клер клэр лара ада эшли шева ева сара сэра кейт кэт кэтрин катрина джейн дженни дженнифер джессика эмили эмма аманда трейси патриция мэри мерседес изабелла изабель анджела анжела мишель наташа рейчел рэчел ребекка
    linda monica lisa liz betty barbara nancy karen donna chloe stacy christina kristen helen elena anna maria mary kate katherine catherine sarah sara lucia ellie abby vicky vicki victoria jill claire lara ada ashley eva eve emily emma amanda tracy patricia jane jennifer jessica angela michelle rebecca rachel
    продавщица охранница туристка женщина девушка официантка медсестра жительница
    """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let ambiguous: Set<String> = ["саша", "женя", "валя", "шура", "сэм", "sam", "alex", "алекс", "ким", "kim", "джей", "jay", "джесси", "jesse", "jessie", "робин", "robin"]

    static func infer(_ name: String) -> Gender? {
        let words = SubtitleNameRouting.normalized(name)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard let first = words.first, !ambiguous.contains(first) else { return nil }
        if ["мистер", "мсье", "сэр", "mr", "sir"].contains(first) { return .male }
        if ["мисс", "миссис", "мадам", "ms", "mrs", "miss"].contains(first) { return .female }
        if first == "местный", words.dropFirst().first == "житель" { return .male }
        if first == "местная", words.dropFirst().first == "жительница" { return .female }
        if male.contains(first) { return .male }
        if female.contains(first) { return .female }
        return nil
    }
}
