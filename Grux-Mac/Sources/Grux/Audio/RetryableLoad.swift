import Foundation

/// Loads one expensive thing once, and lets a FAILED load be tried again.
///
/// Both Whisper owners (`AmbientListener`, `VoiceInput`) kept their model load in a
/// stored `Task`. Measured 2026-09-27: a load that failed because the model folder was
/// not readable stayed the answer until relaunch, and every later ask awaited the
/// finished task and got nil in 24 ms without trying, so `grux transcribe`, dictation
/// and meeting capture stayed dead after the cause was gone. Here a success is kept,
/// callers that arrive during a load share it, and a failure is kept only as the reason,
/// so the next ask loads again.
@MainActor
final class RetryableLoad<Value> {
    private(set) var value: Value?
    /// Why the last load failed, cleared by a success. Lets a refusal name the real cause
    /// instead of guessing at one.
    private(set) var lastFailure: Error?
    private var inFlight: Task<Result<Value, Error>, Never>?
    private let load: () async throws -> Value

    init(_ load: @escaping () async throws -> Value) { self.load = load }

    /// The loaded value, loading it first when nothing has, or nil when this attempt failed.
    func get() async -> Value? {
        if let value { return value }
        let task: Task<Result<Value, Error>, Never>
        if let running = inFlight {
            task = running
        } else {
            let load = self.load
            task = Task.detached(priority: .userInitiated) {
                do { return .success(try await load()) } catch { return .failure(error) }
            }
            inFlight = task
        }
        let result = await task.value
        if inFlight == task { inFlight = nil }
        switch result {
        case .success(let v):
            value = v
            lastFailure = nil
            return v
        case .failure(let e):
            lastFailure = e
            return nil
        }
    }
}
