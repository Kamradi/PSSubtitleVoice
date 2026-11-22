import Foundation

/// A bounded local JSON-lines journal. File I/O stays off the capture and UI threads.
final class DiagnosticLog {
    static let shared = DiagnosticLog()
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("diagnostic.jsonl") }
    private let queue = DispatchQueue(label: "PSSubtitleVoice.log", qos: .utility)
    private let session = UUID().uuidString
    private let maximumBytes: Int
    private var sequence = 0
    private var writeError: String?

    init(directory: URL? = nil, maximumBytes: Int = 2_000_000) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appendingPathComponent("PSSubtitleVoice/Logs", isDirectory: true)
        self.maximumBytes = maximumBytes
        record("session.begin", ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "check",
                                  "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                  "pid": ProcessInfo.processInfo.processIdentifier])
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        let date = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                formatter.timeZone = .current
                self.sequence += 1
                let entry: [String: Any] = ["time": formatter.string(from: date), "uptime": uptime,
                                            "session": self.session, "sequence": self.sequence,
                                            "event": event, "details": fields]
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
                data.append(10)
                if let size = try? self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size + data.count > self.maximumBytes {
                    let oldest = self.directory.appendingPathComponent("diagnostic.3.jsonl")
                    if FileManager.default.fileExists(atPath: oldest.path) { try FileManager.default.removeItem(at: oldest) }
                    for index in stride(from: 2, through: 0, by: -1) {
                        let source = index == 0 ? self.fileURL : self.directory.appendingPathComponent("diagnostic.\(index).jsonl")
                        let target = self.directory.appendingPathComponent("diagnostic.\(index + 1).jsonl")
                        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: target) }
                    }
                }
                if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                    guard FileManager.default.createFile(atPath: self.fileURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: self.fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                self.writeError = nil
            } catch { self.writeError = error.localizedDescription }
        }
    }

    /// Flush queued writes before revealing the journal or exiting normally.
    @discardableResult func flush() -> String? { queue.sync { writeError } }
}
