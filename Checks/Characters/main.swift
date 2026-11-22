import Foundation

var routing = CharacterVoiceContinuity()
precondition(routing.resolve(nil, at: 0) == nil)
precondition(routing.resolve("speaker-2", at: 1) == "speaker-2")
precondition(routing.resolve(nil, at: 4) == "speaker-2")
precondition(routing.resolve(nil, at: 8) == "speaker-2")
precondition(routing.resolve(nil, at: 10) == nil, "Uncertain observations must not extend the hold")
precondition(routing.resolve("speaker-1", at: 11) == "speaker-1", "An identified new speaker must switch immediately")
precondition(routing.resolve(nil, at: 12) == "speaker-1")
routing = CharacterVoiceContinuity()
precondition(routing.resolve(nil, at: 12) == nil, "Reset must clear the old speaker")
print("PASS: unknown audio preserves confirmed voice, expiry, switching and reset")
