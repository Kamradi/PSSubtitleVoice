import Foundation

struct SpeechQueue {
    struct Item {
        let id: UUID
        let text: String
        let addedAt: TimeInterval
    }
    private(set) var items: [Item] = []
    let capacity: Int
    let maximumAge: TimeInterval

    init(capacity: Int = 4, maximumAge: TimeInterval = 25) {
        self.capacity = max(1, capacity)
        self.maximumAge = maximumAge
    }

    @discardableResult
    mutating func append(_ text: String, now: TimeInterval, id: UUID = UUID()) -> Int {
        var dropped = removeExpired(now: now)
        if items.count >= capacity {
            let item = items.removeFirst()
            DiagnosticLog.shared.record("speech.queue_dropped", ["speechID": item.id.uuidString, "text": item.text, "reason": "capacity"])
            dropped += 1
        }
        items.append(Item(id: id, text: text, addedAt: now))
        return dropped
    }

    mutating func next(now: TimeInterval) -> (text: String?, dropped: Int, id: UUID?) {
        let dropped = removeExpired(now: now)
        let item = items.isEmpty ? nil : items.removeFirst()
        return (item?.text, dropped, item?.id)
    }

    mutating func clear() { items.removeAll() }

    private mutating func removeExpired(now: TimeInterval) -> Int {
        let count = items.count
        items.removeAll { item in
            guard now - item.addedAt > maximumAge else { return false }
            DiagnosticLog.shared.record("speech.queue_dropped", ["speechID": item.id.uuidString, "text": item.text, "reason": "expired", "age": now - item.addedAt])
            return true
        }
        return count - items.count
    }
}
