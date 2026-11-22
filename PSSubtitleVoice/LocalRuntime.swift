import Foundation

/// Starts the bundled service; user data stays in the existing app container.
actor LocalRuntime {
    static let shared = LocalRuntime()
    private var startup: Task<Void, Error>?
    private var process: Process?

    func ensureStarted() async throws {
        if let health = try? await SileroClient.shared.health(), health.ready, (health.protocolVersion ?? 0) >= 14 { return }
        if let startup { try await startup.value; return }
        let task = Task { try await self.launch() }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func launch() async throws {
        guard let resources = Bundle.main.resourceURL else { throw failure("Не найдены файлы приложения.") }
        let python = resources.appendingPathComponent("Python/bin/python3.12")
        let runtime = resources.appendingPathComponent("Runtime")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw failure("Локальный движок не включён в эту сборку. Откройте готовое приложение из папки Distribution.")
        }
        if let health = try? await SileroClient.shared.health(), (health.protocolVersion ?? 0) < 14 {
            try? await SileroClient.shared.shutdown()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PSSubtitleVoice/Silero", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let log = support.appendingPathComponent("service.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-u", runtime.appendingPathComponent("silero_service.py").path,
                           "--model", runtime.appendingPathComponent("v5_5_ru.pt").path,
                           "--state", support.appendingPathComponent("service.json").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = resources.appendingPathComponent("Python").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        child.environment = environment
        child.currentDirectoryURL = support
        child.standardOutput = handle; child.standardError = handle
        child.standardInput = FileHandle.nullDevice
        try child.run()
        process = child
        DiagnosticLog.shared.record("runtime.launch", ["pid": child.processIdentifier])
        for _ in 0..<120 {
            if let health = try? await SileroClient.shared.health(), health.ready, (health.protocolVersion ?? 0) >= 14 { return }
            if !child.isRunning { throw failure("Движок озвучивания не запустился. Подробности в журнале службы.") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if child.isRunning { child.terminate() }
        throw failure("Движок не успел запуститься. Нажмите «Проверить» в настройках сервиса.")
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "LocalRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
