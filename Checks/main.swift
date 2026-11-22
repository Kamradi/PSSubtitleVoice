import Foundation
import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError(label) }
}
func stable(_ text: String, tracker: inout SubtitleTracker, at time: TimeInterval) -> String? {
    _ = tracker.accept(text, at: time)
    return tracker.accept(text, at: time + 0.30)
}
var tracker = SubtitleTracker()
expect(tracker.accept("Нам нужно добраться до машины.", at: 0) == nil, "Wait for stability")
expect(tracker.accept("Нам нужно добраться до машины.", at: 0.10) == nil, "Two quick readings are not stable yet")
expect(tracker.accept("Нам нужно добраться до машины.", at: 0.30) != nil, "Read stable dialogue")
expect(stable("Нам нужно добраться до машнны!", tracker: &tracker, at: 1) == nil, "Suppress a minor long-word OCR variation")
expect(stable("Скорее, они уже идут!", tracker: &tracker, at: 2) != nil, "Read B")
expect(stable("Нам нужно добраться до машины.", tracker: &tracker, at: 3) == nil, "Suppress A-B-A")
_ = tracker.accept("", at: 4)
_ = tracker.accept("", at: 10)
expect(stable("Нам нужно добраться до машины.", tracker: &tracker, at: 11) == nil, "Silence must not reset session memory")
expect(stable("У нас есть выход", tracker: &tracker, at: 12) != nil, "Read positive")
expect(stable("У нас нет выхода", tracker: &tracker, at: 13) != nil, "Preserve negation")
expect(stable("Нам нужно пройти еще 10 метров", tracker: &tracker, at: 14) != nil, "Read number")
expect(stable("Нам нужно пройти еще 20 метров", tracker: &tracker, at: 15) != nil, "Preserve number changes")
expect(stable("Он был там", tracker: &tracker, at: 16) != nil, "Read short words")
expect(stable("Он бил там", tracker: &tracker, at: 17) != nil, "Do not fuzzy-match short words")
expect(stable("Нам нужно добраться до машины. Жди меня у моста!", tracker: &tracker, at: 18) == "Жди меня у моста!", "Read only the growing tail")
tracker.release("Жди меня у моста!")
expect(stable("Нам нужно добраться до машины. Жди меня у моста!", tracker: &tracker, at: 19) == "Жди меня у моста!", "Allow canceled tail again")
tracker.reset()
expect(stable("Нам нужно добраться до машины.", tracker: &tracker, at: 20) != nil, "Explicit reset permits scene replay")
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var regression = SubtitleTracker()
expect(stable("Тише, тище. Это ведь ты воруешь чужие контракты.", tracker: &regression, at: 0) != nil, "Accept first OCR reading")
expect(stable("Тише, тише. Это ведь ты воруешь чужие контракты.", tracker: &regression, at: 1) == nil, "Suppress ш/щ OCR duplicate from live log")
expect(stable("Hy,", tracker: &regression, at: 2) == nil, "Do not send Latin-only OCR noise to Russian TTS")
expect(regression.lastDecision == "waiting_for_stability", "Brief Latin OCR noise waits for stronger confirmation")
expect(stable("NO STEP", tracker: &regression, at: 3) == nil, "Brief English scenery text is not read immediately")
expect(stable("Ну,", tracker: &regression, at: 4) != nil, "Keep short Russian dialogue")
var english = SubtitleTracker()
expect(english.accept("Gran Turismo 7", at: 0) == nil, "English waits for observations")
expect(english.accept("Gran Turismo 7", at: 0.30) == nil, "English needs stronger stability")
expect(english.accept("Gran Turismo 7", at: 0.65) == "Gran Turismo 7", "Stable English title is read")
expect(english.accept("Gran Turismo 7", at: 1) == nil, "English repeats are suppressed")
expect(english.accept("12345", at: 2) == nil && english.lastDecision == "unsupported_language", "Digits alone are not dialogue")
expect(stable("Привет, Michael!", tracker: &english, at: 3) == "Привет, Michael!", "Mixed-language text keeps all words")
print("PASS: tracker checks including English titles, mixed text, duplicate and brief-noise regressions")
if CommandLine.arguments.contains("--skip-ocr") { exit(0) }
let image = NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let text = try SubtitleRecognition.text(in: image, region: SubtitleRegion())
expect(SubtitleTracker.normalize(text) == SubtitleTracker.normalize("Нам нужно добраться до машины."), "Sample OCR")
print("PASS: time stability, session memory, A-B-A, punctuation, OCR variations, negatives, numbers, short words, growing tail, canceled tail, explicit reset, sample OCR")
