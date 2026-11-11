import Foundation

/// Runs a Vision request and answers exactly once.
///
/// `VNImageRequestHandler.perform` can call the request's completion handler with
/// an error AND throw that error too. Measured on macOS 27 (public CI run
/// 43029551860, 2026-11-11): "SWIFT TASK CONTINUATION MISUSE: performOCR(on:) tried
/// to resume its continuation more than once", a trap that kills Grux. Every Vision
/// call that waits on a continuation goes through `once`, which keeps the first
/// answer and drops any later one. `VisionContinuationTests` holds the tree to it.
enum VisionRequest {
    /// `start` builds and performs the request. It hands `finish` to the request's
    /// completion handler and may also throw; whichever answers first is the result.
    static func once<T>(
        _ start: (_ finish: @escaping (Result<T, Error>) -> Void) throws -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let first = FirstAnswer(cont)
            do {
                try start { first.answer($0) }
            } catch {
                first.answer(.failure(error))
            }
        }
    }

    /// The continuation, released by the first answer. Locked, because the
    /// completion handler and the throw can arrive on different threads.
    final class FirstAnswer<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?

        init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

        func answer(_ result: Result<T, Error>) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}
