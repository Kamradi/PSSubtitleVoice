import Foundation
let root = FileManager.default.temporaryDirectory.appendingPathComponent("pssubtitle-log-check-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let logger = DiagnosticLog(directory: root, maximumBytes: 3000)
DispatchQueue.concurrentPerform(iterations: 100) { index in
    logger.record("test.event", ["index": index, "text": "Русская фраза\nсо второй строкой и кавычками: \"тест\""])
}
precondition(logger.flush() == nil)
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
precondition(files.count == 4, "Keep exactly current file and three rotated files")
var sequences: [Int] = []
for file in files {
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    precondition(size <= 3000)
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    for line in lines {
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        precondition(value["time"] is String && value["session"] is String)
        sequences.append(value["sequence"] as! Int)
        if value["event"] as? String == "test.event" {
            let details = value["details"] as! [String: Any]
            precondition(details["text"] as? String == "Русская фраза\nсо второй строкой и кавычками: \"тест\"")
        }
    }
}
precondition(Set(sequences).count == sequences.count)
let sorted = sequences.sorted()
precondition(sorted.last == 101)
precondition(sorted == Array(sorted.first!...sorted.last!))
let invalid = root.appendingPathComponent("not-a-directory")
try Data("x".utf8).write(to: invalid)
let failingLogger = DiagnosticLog(directory: invalid)
failingLogger.record("test.failure")
precondition(failingLogger.flush() != nil, "Report write failures")
print("PASS: concurrent logging, valid JSON, Russian text, rotation bounds, ordered sequences, write failure reporting")
