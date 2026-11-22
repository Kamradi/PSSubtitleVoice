import Foundation
import Translation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

Task { @MainActor in
    check(LocalTranslation.needsTranslation("Come on, we have 25 seconds!"), "English dialogue")
    check(!LocalTranslation.needsTranslation("Идём в Los Santos!"), "Russian dialogue retains English names")
    check(!LocalTranslation.needsTranslation("2026"), "Digits stay in Russian speech path")
    let engine = LocalTranslation()
    engine.prepare()
    engine.complete(engine.request!.id, result: .success(""))
    let task = Task { try await engine.translate("Stay here.") }
    await Task.yield()
    let request = engine.request!
    engine.complete(request.id, result: .success("Оставайся здесь."))
    let translated = try! await task.value
    check(translated == "Оставайся здесь.", "Translated result")
    let cached = try! await engine.translate("Stay here.")
    check(cached == "Оставайся здесь." && engine.request == nil, "Cache avoids a second translation")
    let cancelled = Task { try await engine.translate("Wait for me.") }
    await Task.yield()
    let oldID = engine.request!.id
    cancelled.cancel()
    do { _ = try await cancelled.value; fatalError("Cancellation must throw") }
    catch { check(error is CancellationError, "Cancellation propagated") }
    let next = Task { try await engine.translate("Let's go.") }
    await Task.yield()
    engine.complete(oldID, result: .success("obsolete"))
    check(engine.request != nil, "Late result cannot complete the next request")
    engine.complete(engine.request!.id, result: .success("Идём."))
    let nextText = try! await next.value
    check(nextText == "Идём.", "Next request survives cancellation")
    var game = GameProfile(id: "legacy", name: "Test")
    let legacy = try! JSONEncoder().encode(game)
    check(try! JSONDecoder().decode(GameProfile.self, from: legacy).translateEnglish == nil, "Old profiles decode with translation off")
    game.translateEnglish = true
    let saved = try! JSONEncoder().encode(game)
    check(try! JSONDecoder().decode(GameProfile.self, from: saved).translateEnglish == true, "Translation choice persists per game")
    print("Translation queue and profile checks passed")
    if #available(macOS 15.0, *) {
        let status = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "ru"))
        print("Apple EN-RU availability: \(status)")
    }
    exit(0)
}
dispatchMain()
