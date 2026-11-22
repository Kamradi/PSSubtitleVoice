import Foundation

// Unknown audio is not evidence that the speaker changed.
struct CharacterVoiceContinuity {
    private var lastID: String?
    private var confirmedAt: TimeInterval = 0

    mutating func resolve(_ identified: String?, at time: TimeInterval) -> String? {
        if let identified {
            lastID = identified
            confirmedAt = time
            return identified
        }
        // Do not extend this deadline on uncertain observations or across a long silence.
        return time - confirmedAt <= 8 ? lastID : nil
    }
}
