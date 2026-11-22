import Foundation
import ImageIO
import Darwin

/// Vision lives in an inherited-sandbox helper. A stuck system inference can be killed.
final class OCRProcess {
    private struct Connection {
        let process: Process
        let input: FileHandle
        let output: FileHandle
    }
    private let lock = NSLock()
    private var connection: Connection?
    private var closed = false

    var requestTimeout: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return connection == nil ? 45 : 3
    }

    func reset(close: Bool = false) {
        lock.lock()
        if close { closed = true }
        let old = connection; connection = nil
        lock.unlock()
        if let old, old.process.isRunning {
            kill(old.process.processIdentifier, SIGKILL)
        }
        // Killing closes the child's pipe endpoints and unblocks a pending read.
        // Its transaction retains the FileHandles until that read has returned.
    }

    deinit { reset(close: true) }

    private func connect() throws -> Connection {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        if let connection, connection.process.isRunning { return connection }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Helpers/PSSubtitleOCR"),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw failure("В сборке отсутствует процесс распознавания. Откройте установленное приложение.")
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = url
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let value = Connection(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        _ = fcntl(value.input.fileDescriptor, F_SETNOSIGPIPE, 1)
        connection = value
        DiagnosticLog.shared.record("ocr.helper_started", ["pid": process.processIdentifier])
        return value
    }

    func recognize(_ image: CGImage, region: SubtitleRegion) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssv-ocr-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw failure("Не удалось подготовить кадр для распознавания.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("Не удалось сохранить временный кадр.") }
        let child = try connect()
        var request = try JSONSerialization.data(withJSONObject: ["path": url.path, "height": region.height, "bottom": region.bottom, "width": region.width, "ignorePlates": region.ignoreVehiclePlates, "dialogueOnly": region.dialogueOnly])
        request.append(10)
        try child.input.write(contentsOf: request)
        var response = Data()
        while response.count <= 128_000 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(child.output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw failure("Процесс распознавания завершился. Следующий кадр будет обработан новым процессом.")
            }
            response.append(contentsOf: bytes.prefix(count))
            if response.contains(10) { break }
        }
        let object = try JSONSerialization.jsonObject(with: response) as? [String: String]
        if let text = object?["text"] { return text }
        throw failure(object?["error"] ?? "Некорректный ответ процесса распознавания.")
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "OCRProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
