import Foundation

let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let finished = DispatchSemaphore(value: 0)
let stopped = CaptureFrameWorker(timeout: 1) { fatalError("Stopped worker must not time out") }
precondition(stopped.submit(work: { entered.signal(); release.wait(); finished.signal(); return 1 }, completion: { _ in fatalError("Stopped OCR must not deliver") }))
precondition(entered.wait(timeout: .now() + 1) == .success)
precondition(!stopped.submit(work: { 2 }, completion: { _ in fatalError("No queued OCR backlog") }))
let began = Date()
stopped.stop()
precondition(Date().timeIntervalSince(began) < 0.1, "Stop must not wait for a hung recognizer")
release.signal()
precondition(finished.wait(timeout: .now() + 1) == .success)
let timedOut = DispatchSemaphore(value: 0)
let releaseTimed = DispatchSemaphore(value: 0)
let timed = CaptureFrameWorker(timeout: 0.05) { timedOut.signal() }
precondition(timed.submit(work: { releaseTimed.wait(); return 3 }, completion: { _ in fatalError("Late OCR cannot affect another capture session") }))
precondition(timedOut.wait(timeout: .now() + 1) == .success)
let recovered = DispatchSemaphore(value: 0)
precondition(!timed.submit(work: { 4 }, completion: { _ in fatalError("No backlog behind timed-out work") }))
releaseTimed.signal()
var accepted = false
for _ in 0..<100 {
    if timed.submit(work: { 4 }, completion: { _ in recovered.signal() }) { accepted = true; break }
    Thread.sleep(forTimeInterval: 0.001)
}
precondition(accepted)
precondition(recovered.wait(timeout: .now() + 1) == .success)
let delivered = DispatchSemaphore(value: 0)
let normal = CaptureFrameWorker(timeout: 1) { fatalError("Normal OCR timed out") }
precondition(normal.submit(work: { "Text" }, completion: { result in precondition(try! result.get() == "Text"); delivered.signal() }))
precondition(delivered.wait(timeout: .now() + 1) == .success)
normal.stop()
print("PASS: hung OCR does not block stop; single in-flight frame; timeout; stale completion discarded; normal result delivered")
