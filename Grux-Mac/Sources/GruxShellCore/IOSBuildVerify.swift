import Foundation

// MARK: - IOSBuildVerify
//
// Runs `xcodebuild` for an iOS Simulator destination and returns a structured
// IOSBuildResult. Critically it parses compiler error lines into
// IOSBuildError objects so Claude can iterate on specific files/lines rather
// than stare at a wall of text.

public enum IOSBuildVerify {

    public static func build(projectPath: String,
                             scheme: String,
                             destination: String = "") async throws -> IOSBuildResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectPath) else {
            throw IOSToolError.buildFailed("project not found at \(projectPath)")
        }

        // `generic/platform=iOS Simulator` hangs on Xcode 16.x with iOS 26.x
        // SDKs while SWBBuildService waits on a device enumeration that never
        // completes. Resolving a concrete simulator UDID up front sidesteps it.
        let resolvedDestination: String = {
            if !destination.isEmpty { return destination }
            if let udid = firstAvailableIPhoneSimulatorUDID() {
                return "platform=iOS Simulator,id=\(udid)"
            }
            return "generic/platform=iOS Simulator"
        }()

        let start = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let derivedData = tempDerivedDataPath()
        proc.arguments = [
            "xcodebuild",
            "-project", projectPath,
            "-scheme", scheme,
            "-destination", resolvedDestination,
            "-configuration", "Debug",
            "-derivedDataPath", derivedData,
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "build"
        ]
        // Drain stdout/stderr concurrently via readabilityHandler - otherwise
        // xcodebuild blocks in write() once the 64KB pipe buffer fills while
        // we're still in waitUntilExit(). Classic pipe deadlock.
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outLock = NSLock()
        var outBuf = Data()
        var errBuf = Data()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            outLock.lock(); outBuf.append(d); outLock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            outLock.lock(); errBuf.append(d); outLock.unlock()
        }

        try proc.run()
        proc.waitUntilExit()

        // Drain any residual bytes + detach handlers.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let residualOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
        let residualErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
        outLock.lock()
        if let d = residualOut { outBuf.append(d) }
        if let d = residualErr { errBuf.append(d) }
        let out = String(data: outBuf, encoding: .utf8) ?? ""
        let err = String(data: errBuf, encoding: .utf8) ?? ""
        outLock.unlock()
        let combined = out + "\n" + err

        let (errors, warnings) = parseDiagnostics(combined)

        // Locate the built .app - xcodebuild writes it to
        //   <derived>/Build/Products/Debug-iphonesimulator/<scheme>.app
        let expectedApp = (derivedData as NSString)
            .appendingPathComponent("Build/Products/Debug-iphonesimulator/\(scheme).app")
        let appPath: String? = fm.fileExists(atPath: expectedApp) ? expectedApp : nil

        let duration = Date().timeIntervalSince(start)
        let tail = String(combined.suffix(2048))
        return IOSBuildResult(
            success: proc.terminationStatus == 0,
            exitCode: proc.terminationStatus,
            appPath: appPath,
            errors: errors,
            warnings: warnings,
            durationSec: duration,
            stdoutTail: tail
        )
    }

    // MARK: - Error parsing
    //
    // xcodebuild/swiftc emit a `file.swift:line:col: error: message` pattern for
    // nearly everything. Linker errors look different (ld: multiple definitions
    // of …) but we catch those with a broader "error:" fallback.

    static func parseDiagnostics(_ text: String) -> (errors: [IOSBuildError], warnings: [IOSBuildError]) {
        var errors: [IOSBuildError] = []
        var warnings: [IOSBuildError] = []
        let lines = text.components(separatedBy: "\n")
        // Regex: optional path with spaces allowed, :line:col:, severity, message.
        // Using NSRegularExpression to stay on all macOS SDKs.
        let pattern = "^(.+?):(\\d+):(\\d+):\\s+(error|warning):\\s+(.+)$"
        let re = try? NSRegularExpression(pattern: pattern, options: [])
        for line in lines {
            let ns = line as NSString
            if let re, let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let file = ns.substring(with: m.range(at: 1))
                let ln = Int(ns.substring(with: m.range(at: 2)))
                let col = Int(ns.substring(with: m.range(at: 3)))
                let sev = ns.substring(with: m.range(at: 4))
                let msg = ns.substring(with: m.range(at: 5))
                let d = IOSBuildError(file: file, line: ln, column: col, message: msg, severity: sev)
                if sev == "error" { errors.append(d) } else { warnings.append(d) }
                continue
            }
            // Linker / generic error fallback - captures "error: ..." that isn't
            // tied to a specific source file.
            if line.contains(" error: ") || line.hasPrefix("error: ") {
                let msg = line
                    .replacingOccurrences(of: "error: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !msg.isEmpty {
                    errors.append(IOSBuildError(file: "(linker/driver)", line: nil, column: nil,
                                                message: msg, severity: "error"))
                }
            }
        }
        return (errors, warnings)
    }

    private static func tempDerivedDataPath() -> String {
        // Unique per-call so concurrent scaffolds don't clobber each other.
        let base = NSTemporaryDirectory() + "grux-ios-derived/"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base + UUID().uuidString
    }

    // Resolve the first available iPhone simulator UDID via `simctl list -j`.
    // Preference order: already-booted iPhone → newest iPhone name by sort →
    // any iPhone. Returns nil if parsing fails; caller falls back to generic.
    private static func firstAvailableIPhoneSimulatorUDID() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["xcrun", "simctl", "list", "devices", "available", "-j"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = obj["devices"] as? [String: Any]
        else { return nil }

        var booted: String?
        var candidates: [(name: String, udid: String)] = []
        for (_, raw) in devicesByRuntime {
            guard let list = raw as? [[String: Any]] else { continue }
            for d in list {
                guard
                    let name = d["name"] as? String,
                    let udid = d["udid"] as? String,
                    let isAvail = d["isAvailable"] as? Bool, isAvail,
                    name.hasPrefix("iPhone")
                else { continue }
                let state = (d["state"] as? String) ?? ""
                if state.lowercased() == "booted", booted == nil { booted = udid }
                candidates.append((name, udid))
            }
        }
        if let b = booted { return b }
        // Prefer newer-sounding names (iPhone 17 > iPhone 16 > …) via lexical sort desc.
        return candidates.sorted { $0.name > $1.name }.first?.udid
    }
}
