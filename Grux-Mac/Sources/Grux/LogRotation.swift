import Foundation

// Shared size-capped log rotation for the unbounded append-only logs under
// ~/Library/Application Support/Grux (wake.log, security-audit.log,
// music-ranking.log, and friends). Without this, those files grew without
// bound: wake.log was observed at 14MB, which slowed grep-based debugging and
// inflated every backup archive.
//
// Policy: append the line, and when the file crosses maxBytes, roll the live
// file to foo.log.1 (overwriting any existing .1, keeping only `keep` rotated
// copies) and start a fresh foo.log. Synchronous and best-effort: these are
// low-frequency writes, and an IO failure must never crash a caller, so every
// error is swallowed (logged to stderr via NSLog) rather than thrown.

enum LogRotation {

    /// Append `line` to `fileURL`, rotating the file first if it has grown past
    /// `maxBytes`. The caller supplies the full line including any trailing
    /// newline: this helper does not add or strip anything.
    ///
    /// - Parameters:
    ///   - line: the exact bytes to append (caller owns the line format).
    ///   - fileURL: the live log file.
    ///   - maxBytes: rotate once the live file is at or above this size.
    ///   - keep: how many rotated copies to retain (foo.log.1 ... foo.log.<keep>).
    static func appendRotating(_ line: String, to fileURL: URL, maxBytes: Int = 5_000_000, keep: Int = 1) {
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default

        // Rotate before appending if the live file is already at the cap, so a
        // single oversized line never blows far past maxBytes unbounded.
        if let size = fileSize(of: fileURL, fm: fm), size >= maxBytes {
            rotate(fileURL: fileURL, keep: keep, fm: fm)
        }

        if !fm.fileExists(atPath: fileURL.path) {
            do {
                try data.write(to: fileURL)
            } catch {
                NSLog("[Grux/log] create failed for %@: %@", fileURL.lastPathComponent, error.localizedDescription)
            }
            return
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("[Grux/log] append failed for %@: %@", fileURL.lastPathComponent, error.localizedDescription)
            }
        } else {
            // File vanished between the existence check and the open. Recreate.
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Internals

    private static func fileSize(of url: URL, fm: FileManager) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }

    /// Shift foo.log -> foo.log.1, dropping copies beyond `keep`. With keep=1
    /// this simply overwrites foo.log.1 with the current foo.log.
    private static func rotate(fileURL: URL, keep: Int, fm: FileManager) {
        guard keep >= 1 else {
            // No rotated copies wanted: just clear the live file.
            try? fm.removeItem(at: fileURL)
            return
        }

        let base = fileURL.path

        // Drop the oldest copy that would fall off the end of the ring.
        let oldest = URL(fileURLWithPath: "\(base).\(keep)")
        try? fm.removeItem(at: oldest)

        // Slide foo.log.(n) -> foo.log.(n+1) from the back forward.
        var index = keep - 1
        while index >= 1 {
            let from = URL(fileURLWithPath: "\(base).\(index)")
            let to = URL(fileURLWithPath: "\(base).\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            index -= 1
        }

        // Finally move the live file into the .1 slot, leaving room for a fresh one.
        let firstRotated = URL(fileURLWithPath: "\(base).1")
        try? fm.removeItem(at: firstRotated)
        do {
            try fm.moveItem(at: fileURL, to: firstRotated)
        } catch {
            // If the move failed for any reason, fall back to truncating in place
            // so the live file still gets capped.
            NSLog("[Grux/log] rotate failed for %@: %@", fileURL.lastPathComponent, error.localizedDescription)
            try? fm.removeItem(at: fileURL)
        }
    }
}
