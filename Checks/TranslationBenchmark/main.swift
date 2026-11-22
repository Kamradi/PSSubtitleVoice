import Foundation
import Translation
Task {
    let source = Locale.Language(identifier: "en")
    let target = Locale.Language(identifier: "ru")
    let status = await LanguageAvailability().status(from: source, to: target)
    print("Languages: \(status)")
    guard status == .installed else { exit(2) }
    let session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
    for text in ["Get in the car. We have 25 seconds before they find us.", "Stay here. I'll be back soon.", "We need to get out of here before the police arrive."] {
        let began = Date()
        do {
            let response = try await session.translate(text)
            print(String(format: "%.3f s", Date().timeIntervalSince(began)), text, "=>", response.targetText)
        } catch { print(error); exit(3) }
    }
    exit(0)
}
dispatchMain()
