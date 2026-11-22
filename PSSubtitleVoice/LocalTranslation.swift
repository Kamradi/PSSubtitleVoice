import Foundation
import SwiftUI
import Translation

/// One translation belongs to the existing speech queue. No second playback queue.
@MainActor
final class LocalTranslation: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let text: String?
    }
    @Published private(set) var request: Request?
    @Published private(set) var ready = false
    @Published private(set) var status = "Включите перевод и подготовьте языки один раз."
    private var pending: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var cache: [String: String] = [:]

    static func needsTranslation(_ text: String) -> Bool {
        text.range(of: "[A-Za-z]", options: .regularExpression) != nil
            && text.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil
    }

    func prepare() {
        guard pending == nil, request == nil else { return }
        ready = false
        status = "Подготавливаю английский и русский языки…"
        request = Request(text: nil)
    }

    func translate(_ text: String) async throws -> String {
        try Task.checkCancellation()
        guard Self.needsTranslation(text) else { return text }
        if let value = cache[text] { return value }
        guard ready, request == nil else { throw failure("Перевод ещё не готов. Подготовьте языки в настройках перевода.") }
        let item = Request(text: text)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                status = "Перевожу на русский…"
                request = item
                if #available(macOS 26.0, *) {
                    worker = Task { [weak self] in
                        let session: TranslationSession
                        if #available(macOS 26.4, *) {
                            session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "ru"), preferredStrategy: .lowLatency)
                        } else {
                            session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "ru"))
                        }
                        do {
                            let translated = try await withTaskCancellationHandler {
                                try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                            } onCancel: { session.cancel() }
                            guard !translated.isEmpty else { throw self?.failure("Переводчик вернул пустой текст.") ?? CancellationError() }
                            self?.complete(item.id, result: .success(translated))
                        } catch { self?.complete(item.id, result: .failure(error)) }
                    }
                }
                deadline = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.complete(item.id, result: .failure(self?.failure("Перевод занял слишком много времени. Реплика пропущена.") ?? CancellationError()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(item.id, result: .failure(CancellationError())) }
        }
    }

    func complete(_ id: UUID, result: Result<String, Error>) {
        guard let item = request, item.id == id else { return }
        deadline?.cancel(); deadline = nil
        worker?.cancel(); worker = nil
        let continuation = pending
        pending = nil; request = nil
        switch result {
        case .success(let text):
            ready = true; status = "Английский → русский · локально · готов"
            if let source = item.text {
                if cache.count >= 128 { cache.removeAll() }
                cache[source] = text
            }
        case .failure(let error):
            if item.text == nil { ready = false }
            status = error is CancellationError ? "Перевод отменён" : "Ошибка перевода: " + error.localizedDescription
        }
        continuation?.resume(with: result)
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "LocalTranslation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// The session stays within SwiftUI's translation task, including model-download UI.
@available(macOS 15.0, *)
struct LocalTranslationHost: View {
    @ObservedObject var engine: LocalTranslation
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(engine.$request) { request in
                // @Published emits before assigning the new value. Defer task
                // configuration so its action always sees the matching request.
                Task { @MainActor in
                    await Task.yield()
                    guard engine.request?.id == request?.id else { return }
                    guard let request else { configuration = nil; return }
                    if #available(macOS 26.0, *), request.text != nil { return }
                    if configuration == nil {
                        if #available(macOS 26.4, *) {
                            configuration = .init(source: .init(identifier: "en"), target: .init(identifier: "ru"), preferredStrategy: .lowLatency)
                        } else {
                            configuration = .init(source: .init(identifier: "en"), target: .init(identifier: "ru"))
                        }
                    } else { configuration?.invalidate() }
                }
            }
            .translationTask(configuration) { session in
                guard let request = engine.request else { return }
                do {
                    let result: String
                    if let text = request.text {
                        result = try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !result.isEmpty else { throw NSError(domain: "LocalTranslation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Переводчик вернул пустой текст."]) }
                    } else {
                        try await session.prepareTranslation()
                        _ = try await session.translate("Ready.")
                        result = ""
                    }
                    engine.complete(request.id, result: .success(result))
                } catch { engine.complete(request.id, result: .failure(error)) }
            }
    }
}
