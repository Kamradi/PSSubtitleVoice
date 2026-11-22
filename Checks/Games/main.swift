import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
let suite = "PSSubtitleVoice.GameTests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(try! GameProfileLibrary.load(from: defaults) == nil, "No profiles before migration")
var original = GameProfile(id: "legacy", name: "Прежние настройки")
original.mode = "gender"; original.commonVoice = "baya"; original.regionHeight = 0.13
var game = GameProfile(id: UUID().uuidString, name: "Другая игра")
game.mode = "names"
game.names = [SubtitleNameVoice(name: "Генри", voice: "eugene"), SubtitleNameVoice(name: "Элли", voice: "xenia")]
var library = GameProfileLibrary(selectedID: game.id, games: [original, game])
try library.save(to: defaults)
let restored = try GameProfileLibrary.load(from: defaults)!
check(restored.selectedID == game.id, "Selection survives restart")
check(restored.games[0].mode == "gender" && restored.games[0].regionHeight == 0.13, "Legacy settings are preserved")
check(restored.games[1].mode == "names" && restored.games[1].names.count == 2, "Game-specific mode and names survive restart")
library.games[1].maleVoice = "aidar"; library.games[1].regionHeight = 0.40
try library.save(to: defaults)
check(library.games[0].maleVoice == "eugene" && library.games[0].regionHeight == 0.13, "Editing one game does not mutate another")
let routed = SubtitleNameRouting.resolve("— генри: Мы выбрались.", assignments: game.names, commonVoice: "baya")
check(routed.voice == "eugene" && routed.text == "Мы выбрались.", "Exact explicit prefix routes and strips name")
check(SubtitleNameRouting.resolve("[Элли] Подожди!", assignments: game.names, commonVoice: "baya").voice == "xenia", "Bracketed prefix")
check(SubtitleNameRouting.resolve("Генрий: Привет.", assignments: game.names, commonVoice: "baya").voice == "baya", "No fuzzy name guessing")
for subtitle in ["Джоэл: Тише, тише.", "[Джоэл] Тише, тише.", "— Джоэл: Тише, тише."] {
    let unknown = SubtitleNameRouting.resolve(subtitle, assignments: game.names, commonVoice: "aidar")
    check(unknown.voice == "aidar" && unknown.text == "Тише, тише." && unknown.reason == "unknown_name", "Unknown speaker uses common voice without reading the name")
}
check(SubtitleNameRouting.resolve("Джоэл: Идём.", assignments: [], commonVoice: "eugene").text == "Идём.", "No configured characters required to strip a name")
check(SubtitleNameRouting.resolve("Я встретил Джоэла.", assignments: [], commonVoice: "baya").text == "Я встретил Джоэла.", "Dialogue itself stays intact")
check(SubtitleNameRouting.resolve("Мы встретили Генри.", assignments: game.names, commonVoice: "baya").voice == "baya", "Names inside dialogue do not route")
check(SubtitleNameRouting.resolve("Генри: Жди. Элли: Иду.", assignments: game.names, commonVoice: "baya").reason == "multiple_names", "Multiple joined speakers do not use the first voice")
let duplicate = game.names + [SubtitleNameVoice(name: "ГЕНРИ", voice: "aidar")]
var session = SubtitleNameSession()
check(session.resolve("Начало без имени.", assignments: game.names, commonVoice: "baya").voice == "baya", "No previous speaker uses common voice")
_ = session.resolve("Генри: Первая строка.", assignments: game.names, commonVoice: "baya")
for line in ["Продолжение фразы.", "И ещё одна строка."] {
    let continuation = session.resolve(line, assignments: game.names, commonVoice: "baya")
    check(continuation.voice == "eugene" && continuation.text == line && continuation.name == "Генри", "Multiple unnamed continuations retain speaker")
}
_ = session.resolve("[Элли] Подожди!", assignments: game.names, commonVoice: "baya")
check(session.resolve("Я иду.", assignments: game.names, commonVoice: "baya").voice == "xenia", "Explicit next speaker replaces previous")
_ = session.resolve("Сэм: Привет.", assignments: game.names, commonVoice: "baya")
check(session.resolve("Продолжение Сэма.", assignments: game.names, commonVoice: "baya").voice == "baya", "Unknown speaker and continuation use common voice")
_ = session.resolve("Генри: Жди.", assignments: game.names, commonVoice: "baya")
session.reset()
check(session.resolve("Другая сцена.", assignments: game.names, commonVoice: "baya").voice == "baya", "Reset prevents stale speaker across sessions")
check(SubtitleNameRouting.resolve("Генри: Жди.", assignments: duplicate, commonVoice: "baya").reason == "ambiguous_name", "Duplicate mapping is ambiguous")
let snapshot = defaults.data(forKey: GameProfileLibrary.key)
library.games[1].id = "../../escape"
do { try library.save(to: defaults); fatalError("Invalid profile id saved") } catch {}
check(defaults.data(forKey: GameProfileLibrary.key) == snapshot, "Invalid data does not overwrite saved profiles")
print("PASS: per-game persistence, isolation, explicit names, unknown/multiple/ambiguous fallback, invalid data protection")
var inferredSession = SubtitleNameSession()
func inferRoute(_ text: String) -> SubtitleNameRouting {
    inferredSession.resolve(text, assignments: game.names, commonVoice: "baya", maleVoice: "aidar", femaleVoice: "xenia")
}
check(inferRoute("Вики: Привет.").voice == "xenia", "Unknown mapped female name uses female default")
check(inferRoute("Продолжение без имени.").voice == "xenia", "Inferred voice continues without name")
check(inferRoute("Джоэл: Пойдём.").voice == "aidar", "Unmapped male name uses male default")
check(inferRoute("[Emily] Hello.").voice == "xenia", "English female label")
check(inferRoute("Мистер Смит: Пойдём.").voice == "aidar", "Honorific")
check(inferRoute("Саша: Привет.").voice == "baya", "Ambiguous name remains common")
check(inferRoute("Киберлиса: Привет.").voice == "baya", "Unknown nickname remains common")
check(inferRoute("Я встретил Вики.").voice == "baya", "Dialogue words never select speaker")
check(inferRoute("Генри: Пойдём.").voice == "eugene", "Explicit assignment overrides inferred male default")
inferredSession.reset()
check(inferRoute("Без имени.").voice == "baya", "Reset clears inferred context")
var savedGame = game
savedGame.nameMaleVoice = "aidar"; savedGame.nameFemaleVoice = "xenia"
let encoded = try JSONEncoder().encode(savedGame)
let decoded = try JSONDecoder().decode(GameProfile.self, from: encoded)
check(decoded.nameMaleVoice == "aidar" && decoded.nameFemaleVoice == "xenia", "Both name defaults persist")
var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String:Any]
legacyJSON.removeValue(forKey:"nameMaleVoice"); legacyJSON.removeValue(forKey:"nameFemaleVoice")
let legacy = try JSONDecoder().decode(GameProfile.self, from: JSONSerialization.data(withJSONObject:legacyJSON))
check(legacy.nameMaleVoice == nil && legacy.nameFemaleVoice == nil, "Old profiles decode without new fields")
var invalidDefaults = savedGame; invalidDefaults.nameMaleVoice = "bad-voice"
do {
    try GameProfileLibrary(selectedID:invalidDefaults.id,games:[invalidDefaults]).validate()
    fatalError("Invalid fallback accepted")
} catch {}
print("PASS: inferred defaults, priority, continuation, ambiguity, persistence and migration")
