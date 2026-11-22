import Foundation
import Vision
import CoreGraphics

struct SubtitleRegion {
    var height = 0.30
    var bottom = 0.0
    var width = 0.92
    var ignoreVehiclePlates = true
    var rect: CGRect { CGRect(x: (1 - width) / 2, y: bottom, width: width, height: height) }
}

enum SubtitleRecognition {
    static func text(in image: CGImage, region: SubtitleRegion) throws -> String {
        let request = VNRecognizeTextRequest()
        // Avoid the shared accelerator path that stalled with live translation on macOS 27.
        // Capture has a separate bounded OCR worker, so device callbacks remain responsive.
        request.usesCPUOnly = true
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        guard supported.contains("ru-RU") else {
            throw NSError(domain: "SubtitleRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Эта версия Vision не поддерживает русский язык. Обновите macOS."])
        }
        request.recognitionLanguages = ["ru-RU", "en-US"].filter { supported.contains($0) }
        request.regionOfInterest = region.rect
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines: [SubtitleTextFilter.Line] = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) < 0.015 {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            return SubtitleTextFilter.Line(text: candidate.string,
                bounds: SubtitleTextFilter.frameBounds(observation.boundingBox, region: region.rect))
        }
        let selected = region.ignoreVehiclePlates ? SubtitleTextFilter.subtitleRows(lines) : lines
        let joined = SubtitleTextFilter.filter(selected, enabled: region.ignoreVehiclePlates)
            .map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return region.ignoreVehiclePlates ? SubtitleTextFilter.cleanEdges(joined) : joined
    }
}

/// Applied to individual OCR boxes before dialogue lines are joined. Colour is
/// deliberately not a condition: names and subtitles may themselves be coloured.
enum SubtitleTextFilter {
    struct Line { let text: String; let bounds: CGRect }

    /// A changing poster above a stable subtitle must not restart stability of
    /// the whole frame. Keep sentence rows near the lowest caption and inline
    /// words/names, in either language. Ambiguous frames retain all their text.
    static func subtitleRows(_ lines: [Line]) -> [Line] {
        func sentence(_ line: Line) -> Bool {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = text.filter(\.isLetter)
            let lowercase = letters.filter(\.isLowercase).count
            guard letters.count >= 2, Double(lowercase) / Double(letters.count) >= 0.35,
                  line.bounds.height >= 0.010 else { return false }
            return text.split(whereSeparator: \.isWhitespace).count >= 2
                || text.last.map { ".!?…".contains($0) } == true
        }
        let cues = lines.indices.filter { sentence(lines[$0]) }
        guard let lowest = cues.min(by: { lines[$0].bounds.midY < lines[$1].bounds.midY }) else { return lines }
        let anchor = lines[lowest].bounds
        let selected = cues.filter {
            let box = lines[$0].bounds
            return box.height >= anchor.height * 0.6
                && abs(box.midY - anchor.midY) <= max(box.height, anchor.height) * 2.8
        }
        return lines.enumerated().filter { index, line in
            if selected.contains(index) { return true }
            let explicitName = line.text.hasSuffix(":") || (line.text.hasPrefix("[") && line.text.hasSuffix("]"))
            return selected.contains { cue in
                let box = lines[cue].bounds
                let height = max(box.height, line.bounds.height)
                let gap = max(0, max(box.minX - line.bounds.maxX, line.bounds.minX - box.maxX))
                return line.bounds.height >= box.height * 0.55 && line.bounds.height <= box.height * 1.8
                    && abs(line.bounds.midY - box.midY) <= height * (explicitName ? 1.8 : 0.6)
                    && gap <= height * 4
            }
        }.map(\.element)
    }

    static func filter(_ lines: [Line], enabled: Bool) -> [Line] {
        guard enabled else { return lines }
        var ignored = Set(lines.indices.filter { isTinySceneryLabel(lines[$0]) })
        var plates: [CGRect] = []
        for start in lines.indices where !ignored.contains(start) {
            // A plate may be several OCR boxes, e.g. J26 + 4B7. Only join
            // nearby boxes on the same baseline, never a subtitle above it.
            for count in stride(from: min(4, lines.count - start), through: 1, by: -1) {
                let indices = Array(start..<(start + count))
                guard indices.allSatisfy({ !ignored.contains($0) }) else { continue }
                let group = indices.map { lines[$0] }.sorted { $0.bounds.minX < $1.bounds.minX }
                let height = group.map { $0.bounds.height }.max() ?? 0
                guard group.allSatisfy({ abs($0.bounds.midY - group[0].bounds.midY) <= height * 0.55 }),
                      zip(group, group.dropFirst()).allSatisfy({ $1.bounds.minX - $0.bounds.maxX <= height * 2.5 }) else { continue }
                let bounds = group.dropFirst().reduce(group[0].bounds) { $0.union($1.bounds) }
                if isVehiclePlate(group.map(\.text).joined(separator: " "), bounds: bounds) {
                    ignored.formUnion(indices); plates.append(bounds); break
                }
            }
        }
        for index in lines.indices where !ignored.contains(index) {
            let box = lines[index].bounds
            if plates.contains(where: { plate in
                box.height <= plate.height * 0.9 + 0.001
                    && box.width <= plate.width * 2.5
                    && abs(box.midX - plate.midX) <= plate.width * 1.25
                    && box.minY >= plate.minY - plate.height * 0.5
                    && box.maxY <= plate.maxY + plate.height * 2.5
            }) { ignored.insert(index) }
        }
        return lines.enumerated().filter { !ignored.contains($0.offset) }.map(\.element)
    }
    // Vision's boxes are normalized within the recognition ROI. Size thresholds
    // must use full-frame coordinates, otherwise changing ROI changes filtering.
    static func frameBounds(_ box: CGRect, region: CGRect) -> CGRect {
        CGRect(x: region.minX + box.minX * region.width,
               y: region.minY + box.minY * region.height,
               width: box.width * region.width, height: box.height * region.height)
    }

    private static func isTinySceneryLabel(_ line: Line) -> Bool {
        // Tiny uppercase labels/serial marks on objects, including a plate's
        // state name when its main number is obscured. Normal subtitle fonts
        // and short spoken words such as NO/I stay eligible.
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.bounds.height > 0, line.bounds.height < 0.012,
              !text.isEmpty, text.count <= 18,
              text.unicodeScalars.allSatisfy(\.isASCII), text == text.uppercased() else { return false }
        return text.contains(where: \.isNumber) || text.filter(\.isLetter).count >= 4
    }

    /// Final safeguard for boxes Vision has already merged with a subtitle.
    /// Only code-like edges are stripped; codes within spoken sentences stay intact.
    static func cleanEdges(_ text: String) -> String {
        let text = removingControlHint(text)
        let context = text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
        if context.contains(where: { $0.hasPrefix("номер") || $0.hasPrefix("код") || ["plate", "code", "number", "registration", "license"].contains($0) }) { return text }
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func code(_ parts: [String]) -> Bool {
            guard isPlateCode(parts.joined(separator: " ")) else { return false }
            // Ordinary dates/counts (AT 1234 PM) contain no mixed code token.
            return parts.contains { part in
                part.contains(where: \.isLetter) && part.contains(where: \.isNumber)
            }
        }
        if !words.isEmpty {
            for count in stride(from: min(6, words.count), through: 1, by: -1) {
                if code(Array(words.prefix(count))) { words.removeFirst(count); break }
            }
        }
        if !words.isEmpty {
            for count in stride(from: min(6, words.count), through: 1, by: -1) {
                if code(Array(words.suffix(count))) { words.removeLast(count); break }
            }
        }
        return words.joined(separator: " ")
    }

    static func removingControlHint(_ text: String) -> String {
        // The interaction label can overlap and even be merged into an OCR box.
        // Keep ordinary sentence-case uses of «сесть» and punctuated exclamations.
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return parts.filter { token in
            !(token.lowercased() == "сесть" && token.filter(\.isUppercase).count >= 3)
        }.joined(separator: " ")
    }

    static func isVehiclePlate(_ text: String, bounds: CGRect) -> Bool {
        guard bounds.height > 0, bounds.height <= 0.04, bounds.width <= 0.22 else { return false }
        return isPlateCode(text)
    }

    static func isPlateCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|:;.,_*–—-"))).uppercased()
        guard trimmed.range(of: "^[A-ZА-ЯЁ0-9 \t|-]+$", options: .regularExpression) != nil else { return false }
        let tokens = trimmed.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-|"))).filter { !$0.isEmpty }
        // Preserve actual words, e.g. WAIT 123, UNIT 007, GTA 2026.
        guard !tokens.contains(where: { $0.count >= 3 && $0.allSatisfy(\.isLetter) }) else { return false }
        let compact = tokens.joined()
        let digits = compact.filter(\.isNumber).count
        let letters = compact.filter(\.isLetter).count
        return (6...10).contains(compact.count) && (3...7).contains(digits) && (1...5).contains(letters)
    }
}

// Stability is per source; accepted dialogue is remembered until an explicit reset.
struct SubtitleTracker {
    private var candidate = ""
    private var candidateText = ""
    private var count = 0
    private(set) var firstSeen: TimeInterval = 0
    private var seen = Set<String>()
    private var recent: [String] = []
    private var recentTimes: [String: TimeInterval] = [:]
    private var namedCaptions: [String: (name: String, body: String)] = [:]
    private var sourceAliases: [String: String] = [:]
    private var emittedKeys: [String: Set<String>] = [:]
    private(set) var lastDecision = "initial"
    var stabilitySeconds = 0.24

    mutating func reset() { self = SubtitleTracker(stabilitySeconds: stabilitySeconds) }

    mutating func release(_ text: String) {
        let output = Self.normalize(text)
        let keys = emittedKeys.removeValue(forKey: output) ?? [output]
        seen.subtract(keys)
        recent.removeAll { keys.contains($0) }
        namedCaptions = namedCaptions.filter { !keys.contains($0.key) }
        recentTimes = recentTimes.filter { !keys.contains($0.key) }
        sourceAliases = sourceAliases.filter { !keys.contains($0.key) && !keys.contains($0.value) }
        candidate = ""; candidateText = ""; count = 0
    }

    mutating func accept(_ text: String, at time: TimeInterval) -> String? {
        accept(text, at: time, finalized: false)
    }

    private mutating func accept(_ text: String, at time: TimeInterval, finalized: Bool) -> String? {
        let text = SubtitleTextFilter.removingControlHint(text)
        let key = Self.normalize(text)
        guard !key.isEmpty else {
            let age = time - firstSeen
            if count >= 1, (stabilitySeconds...1.0).contains(age), Self.completeShortCaption(candidateText) {
                let result = accept(candidateText, at: time, finalized: true)
                candidate = ""; candidateText = ""; count = 0
                if result != nil { lastDecision = "accepted_short_lived" }
                return result
            }
            candidate = ""; candidateText = ""; count = 0; lastDecision = "empty"; return nil
        }
        let hasRussian = key.range(of: "[а-я]", options: .regularExpression) != nil
        let latinCount = key.filter { $0.isASCII && $0.isLetter }.count
        guard hasRussian || latinCount >= 2 else {
            candidate = ""; count = 0; lastDecision = "unsupported_language"; return nil
        }
        if !finalized {
            if key == candidate || Self.sameNamedCaption(Self.namedCaption(text), Self.namedCaption(candidateText)) {
                count += 1
            } else { candidate = key; count = 1; firstSeen = time }
            candidateText = text
        }
        // English names are valid speech too. Use extra observations to avoid
        // sending momentary Latin-shaped OCR noise from gameplay to the voice.
        guard finalized || (count >= (hasRussian ? 2 : 3) && time - firstSeen >= (hasRussian ? stabilitySeconds : max(0.6, stabilitySeconds))) else { lastDecision = "waiting_for_stability"; return nil }
        if seen.contains(key) {
            let origin = sourceAliases[key] ?? key
            if recentTimes[origin] != nil { recentTimes[origin] = time }
            lastDecision = "session_duplicate"; return nil
        }
        if let previous = recent.first(where: { Self.similar(key, $0) }) {
            rememberAlias(key, of: previous, at: time)
            lastDecision = "ocr_variation"; return nil
        }
        let active = recent.filter { time - (recentTimes[$0] ?? -.infinity) <= 12 }
        if let previous = active.first(where: { Self.sameNamedCaption(Self.namedCaption(text), namedCaptions[$0]) }) {
            rememberAlias(key, of: previous, at: time)
            lastDecision = "speaker_name_ocr_variation"; return nil
        }
        if let previous = active.first(where: { Self.sameVisibleSentence(key, $0) || Self.longOCRVariation(key, $0) || Self.splitOCRVariation(key, $0) }) {
            rememberAlias(key, of: previous, at: time)
            lastDecision = "mixed_script_ocr_variation"; return nil
        }
        if let previous = active.first(where: { Self.knownFragment(key, of: $0) }) {
            rememberAlias(key, of: previous, at: time)
            lastDecision = "already_read_fragment"; return nil
        }
        if Self.objective(key.split(separator: " ")[...]), let previous = recent.first(where: {
            let old = $0.split(separator: " "), words = key.split(separator: " ")
            return old.count >= words.count && Self.sameObjective(old.suffix(words.count), words[...])
        }) {
            rememberAlias(key, of: previous, at: time)
            lastDecision = "already_read_objective"; return nil
        }
        var output = text
        let tokens = key.split(separator: " ")
        var prefixCount = recent.compactMap { previous -> Int? in
            let words = previous.split(separator: " ")
            return words.count >= 4 && words.count < tokens.count && tokens.starts(with: words) ? words.count : nil
        }.max() ?? 0
        for previous in active {
            let words = previous.split(separator: " ")
            let upper = min(words.count, tokens.count - 1)
            if upper >= 4 {
                for count in stride(from: upper, through: 4, by: -1) where count > prefixCount {
                    let overlap = words.suffix(count)
                    if tokens.starts(with: overlap), overlap.joined(separator: " ").count >= 20 {
                        prefixCount = count; break
                    }
                }
            }
        }
        if prefixCount > 0 {
            let expression = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
            let ns = text as NSString
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            if matches.count > prefixCount { output = ns.substring(from: matches[prefixCount].range.location) }
        }
        // A persistent HUD/SMS block can stay below a new spoken line. Read
        // the new beginning without repeating the already-read whole message.
        let outputTokens = Self.normalize(output).split(separator: " ")
        var suffixCount = 0
        if outputTokens.count > 3 {
            for count in stride(from: outputTokens.count - 1, through: 3, by: -1) {
                let suffix = outputTokens.suffix(count).joined(separator: " ")
                let beginning = outputTokens.dropLast(count).joined(separator: " ")
                if suffix.count >= 15, beginning.count >= 5, seen.contains(suffix) {
                    suffixCount = count; break
                }
            }
        }
        for previous in active {
            let old = previous.split(separator: " ")
            let upper = min(old.count, outputTokens.count - 1)
            if upper >= 2 {
                for count in stride(from: upper, through: 2, by: -1) where count > suffixCount {
                    let suffix = outputTokens.suffix(count)
                    if (old.suffix(count).elementsEqual(suffix) || Self.sameObjective(old.suffix(count), suffix)),
                       (suffix.contains("смс") || suffix.contains("sms") || Self.objective(suffix)),
                       outputTokens.dropLast(count).joined(separator: " ").count >= 5 {
                        suffixCount = count; break
                    }
                }
            }
        }
        if suffixCount > 0 {
            let expression = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
            let ns = output as NSString
            let matches = expression.matches(in: output, range: NSRange(location: 0, length: ns.length))
            if matches.count > suffixCount {
                output = ns.substring(to: matches[matches.count - suffixCount].range.location)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[")))
            }
        }
        let outputKey = Self.normalize(output)
        guard !seen.contains(outputKey) else {
            rememberAlias(key, of: sourceAliases[outputKey] ?? outputKey, at: time)
            lastDecision = "growing_tail_already_seen"; return nil
        }
        seen.insert(key); seen.insert(outputKey)
        recent.append(key); recentTimes[key] = time
        namedCaptions[key] = Self.namedCaption(text)
        if outputKey != key { sourceAliases[outputKey] = key }
        if recent.count > 32 {
            let removed = recent.removeFirst(); recentTimes.removeValue(forKey: removed)
            namedCaptions.removeValue(forKey: removed)
            sourceAliases = sourceAliases.filter { $0.value != removed }
        }
        emittedKeys[outputKey, default: []].formUnion([key, outputKey])
        lastDecision = output == text ? "accepted" : "accepted_growing_tail"
        return output
    }

    private static func namedCaption(_ text: String) -> (name: String, body: String)? {
        let expression = try! NSRegularExpression(pattern: "^\\s*[-–—]?\\s*(?:\\[([^\\]]{1,40})\\]\\s*:?|([\\p{L}][\\p{L}\\p{M}0-9 _'’.-]{0,39}):)\\s*(.+)$", options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let nameRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        return (normalize(ns.substring(with: nameRange)), normalize(ns.substring(with: match.range(at: 3))))
    }

    private static func sameNamedCaption(_ a: (name: String, body: String)?, _ b: (name: String, body: String)?) -> Bool {
        guard let a, let b, a.body == b.body else { return false }
        if a.name == b.name { return true }
        guard min(a.name.count, b.name.count) >= 4,
              !a.name.contains(" "), !b.name.contains(" "),
              !a.name.contains(where: \.isNumber), !b.name.contains(where: \.isNumber) else { return false }
        return editDistance(a.name, b.name) == 1
    }

    private static func completeShortCaption(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...80).contains(trimmed.count), trimmed.last.map({ ".!?…".contains($0) }) == true,
              trimmed.range(of: "[a-zA-Z]", options: .regularExpression) == nil else { return false }
        let words = normalize(trimmed).split(separator: " ")
        return words.filter { $0.range(of: "[а-я]", options: .regularExpression) != nil }.count >= 2
    }

    private mutating func rememberAlias(_ key: String, of previous: String, at time: TimeInterval) {
        seen.insert(key); sourceAliases[key] = previous; recentTimes[previous] = time
        if let output = emittedKeys.first(where: { $0.key == previous || $0.value.contains(previous) })?.key {
            emittedKeys[output, default: []].insert(key)
        }
    }

    private static func knownFragment(_ text: String, of previous: String) -> Bool {
        let words = text.split(separator: " "), old = previous.split(separator: " ")
        guard old.count >= 5, words.count >= 3, words.count < old.count, text.count >= 15 else { return false }
        let protected: Set<String> = ["не", "нет", "ни", "нельзя", "not", "no", "never", "without",
            "ноль", "один", "одна", "одно", "два", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять",
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return (0...(old.count - words.count)).contains { offset in
            guard Array(old[offset..<(offset + words.count)]) == words else { return false }
            let removed = Array(old.prefix(offset)) + Array(old.dropFirst(offset + words.count))
            return !removed.contains { protected.contains(String($0)) || $0.contains(where: \.isNumber) }
        }
    }

    private static func objective(_ words: ArraySlice<Substring>) -> Bool {
        guard let first = words.first else { return false }
        return (first.count >= 6 && first.range(of: "(йтесь|итесь|ите)$", options: .regularExpression) != nil)
            || ["доберитесь", "дождитесь", "найдите", "поговорите", "закажите", "войдите", "возьмите", "вернитесь", "следуйте"].contains(String(first))
    }

    private static func splitOCRVariation(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: " ").map(String.init), right = b.split(separator: " ").map(String.init)
        let longer = left.count > right.count ? left : right
        let shorter = left.count > right.count ? right : left
        guard shorter.count >= 8, longer.count == shorter.count + 1 else { return false }
        for i in 0..<(longer.count - 1) where ["і", "г"].contains(longer[i]) {
            var joined = longer
            joined[i] = "г" + joined[i + 1]
            joined.remove(at: i + 1)
            if joined == shorter { return true }
        }
        return false
    }

    private static func sameObjective(_ left: ArraySlice<Substring>, _ right: ArraySlice<Substring>) -> Bool {
        guard objective(left), objective(right), left.count == right.count,
              left.first == right.first else { return false }
        if left.elementsEqual(right) { return true }
        guard left.count >= 3 else { return false }
        var changes = 0
        for (x, y) in zip(left, right) where x != y {
            guard min(x.count, y.count) >= 4,
                  !x.contains(where: \.isNumber), !y.contains(where: \.isNumber),
                  editDistance(String(x), String(y)) == 1 else { return false }
            changes += 1
            guard changes <= 1 else { return false }
        }
        return true
    }

    // A long caption may contain several independent OCR substitutions. Keep
    // this local to a still-visible caption and preserve short functional words.
    private static func longOCRVariation(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: " ").map(String.init)
        let right = b.split(separator: " ").map(String.init)
        guard left.count >= 10, left.count == right.count else { return false }
        var edits = 0
        for (x, y) in zip(left, right) where x != y {
            guard !x.contains(where: \.isNumber), !y.contains(where: \.isNumber) else { return false }
            let visual = x.replacingOccurrences(of: "л", with: "п") == y.replacingOccurrences(of: "л", with: "п")
            let clipped = min(x.count, y.count) >= 4 && abs(x.count - y.count) <= 2
                && (x.hasPrefix(y) || y.hasPrefix(x))
            guard clipped || (((x.count >= 5 && y.count >= 5) || (visual && min(x.count, y.count) >= 2))
                && editDistance(x, y) == 1) else { return false }
            edits += 1
            guard edits <= 2 else { return false }
        }
        return edits > 0
    }

    private static func sameVisibleSentence(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: " ").map(String.init), right = b.split(separator: " ").map(String.init)
        guard left.count >= 8, left.count == right.count else { return false }
        let russianContext = left.filter { $0.range(of: "[а-я]", options: .regularExpression) != nil }.count >= 4
        var repeatedForeignWords = 0
        for (x, y) in zip(left, right) where x != y {
            guard x.rangeOfCharacter(from: .decimalDigits) == nil,
                  y.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
            func tinyForeign(_ token: String) -> Bool {
                token.count <= 2 && token.unicodeScalars.allSatisfy { (97...122).contains(Int($0.value)) }
                    && !["no", "on", "in", "to", "of", "or", "is", "it", "we", "he", "be", "do", "so", "if", "an", "at", "as"].contains(token)
            }
            func russianWord(_ token: String) -> Bool {
                token.count >= 5 && token.range(of: "^[а-я]+$", options: .regularExpression) != nil
            }
            if left.count >= 10, russianContext,
               (tinyForeign(x) && russianWord(y)) || (tinyForeign(y) && russianWord(x)) {
                repeatedForeignWords += 1
                guard repeatedForeignWords <= 1 else { return false }
                continue
            }
            let foreign = (x + y).range(of: "[a-zіӏ]", options: .regularExpression) != nil
            guard foreign else { return false }
            let italic = (x + y).contains("і") || (x + y).contains("ӏ")
            let l = visualLatin(x, italic: italic), r = visualLatin(y, italic: italic)
            if l == r { continue }
            guard russianContext, x.count >= 4, y.count >= 4,
                  collapseRepeats(l) == collapseRepeats(r) else { return false }
            repeatedForeignWords += 1
            guard repeatedForeignWords <= 1 else { return false }
        }
        return true
    }

    private static func visualLatin(_ text: String, italic: Bool) -> String {
        let lookalikes: [Character: Character] = ["а":"a", "е":"e", "о":"o", "р":"p", "с":"c", "х":"x", "у":"y", "к":"k", "м":"m", "і":"l", "ӏ":"l"]
        return String(text.map { character in
            if italic, character == "т" { return "m" }
            return lookalikes[character] ?? character
        })
    }
    private static func collapseRepeats(_ text: String) -> String {
        var result = ""
        for character in text where result.last != character { result.append(character) }
        return result
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let left = a.split(separator: " ").map(String.init), right = b.split(separator: " ").map(String.init)
        guard left.count >= 5, left.count == right.count else { return false }
        var changes = 0
        for (x, y) in zip(left, right) where x != y {
            // Preserve short words, negation and numbers even if the entire sentence looks similar.
            // Vision often confuses ш/щ in «тише». Only allow this specific
            // four-letter confusion inside a longer, otherwise identical sentence.
            let shortOCRConfusion = left.count >= 8 && x.count == 4 && y.count == 4
                && x.replacingOccurrences(of: "щ", with: "ш") == y.replacingOccurrences(of: "щ", with: "ш")
            guard (x.count >= 5 && y.count >= 5) || shortOCRConfusion,
                  x.rangeOfCharacter(from: .decimalDigits) == nil,
                  y.rangeOfCharacter(from: .decimalDigits) == nil,
                  editDistance(x, y) <= 1 else { return false }
            changes += 1
        }
        return changes <= 1
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let right = Array(b)
        var row = Array(0...right.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: right.count)
            for (j, y) in right.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))
            }
            row = next
        }
        return row.last!
    }
}

final class SubtitleGate {
    private let lock = NSLock()
    private var tracker = SubtitleTracker()
    func process(_ text: String, at time: TimeInterval) -> (speech: String?, decision: String, began: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let speech = tracker.accept(text, at: time)
        return (speech, tracker.lastDecision, tracker.firstSeen)
    }
    func release(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        tracker.release(text)
        DiagnosticLog.shared.record("subtitle.release", ["text": text])
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker.reset()
        DiagnosticLog.shared.record("subtitle.memory_reset")
    }
}
