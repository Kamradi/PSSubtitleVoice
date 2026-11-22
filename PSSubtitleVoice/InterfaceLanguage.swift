import Foundation

/// UI-only translations. Captured dialogue and user-entered names bypass this.
enum InterfaceLanguage {
    static let key = "interfaceLanguage"
    static var code: String { UserDefaults.standard.string(forKey: key) == "en" ? "en" : "ru" }
    private static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()

    static func text(_ value: String) -> String {
        guard code == "en" else { return value }
        if let translated = english[value] { return translated }
        if let arrow = value.range(of: " → ") {
            return String(value[..<arrow.lowerBound]) + " → " + text(String(value[arrow.upperBound...]))
        }
        // Preserve variable values in status/error messages while translating
        // their fixed UI prefix. Raw OCR and subtitle text never call this API.
        for prefix in ["Не удалось начать захват: ", "Захват остановлен: ", "Выбрана игра: ",
                       "Не удалось получить окна: ", "Ошибка перевода: ", "Образцы не приняты: ", "Не удалось записать журнал: "] {
            if value.hasPrefix(prefix), let translated = english[prefix] {
                return translated + text(String(value.dropFirst(prefix.count)))
            }
        }
        if value.hasPrefix("Захват работает · распознавание ") { return "Capture running · OCR " + value.dropFirst("Захват работает · распознавание ".count).replacingOccurrences(of: "мс", with: "ms") }
        if value.hasPrefix("Голос ожидает реплику") { return "Waiting for dialogue" }
        if value.hasPrefix("Читаю") { return "Speaking" }
        return value
    }
}
