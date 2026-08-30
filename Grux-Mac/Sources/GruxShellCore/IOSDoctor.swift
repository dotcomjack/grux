import Foundation

// MARK: - IOSDoctor
//
// Pre-flight for the iOS scaffold pipeline. Verifies the host can actually
// produce a device-ready iPhone build: Xcode is installed, a simulator
// runtime is available, xcodegen is on PATH, and the configured dev team
// (optional) is present. Always returns a report - callers decide whether to
// continue when `allOk` is false.

public enum IOSDoctor {

    public static func diagnose(requireTeamId: Bool = false) async -> IOSDoctorReport {
        var checks: [IOSDoctorReport.Check] = []

        // 1. xcode-select -p
        let xcp = run("/usr/bin/env", args: ["xcode-select", "-p"])
        let xcodePath = xcp.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let xcodeOk = xcp.code == 0 && FileManager.default.fileExists(atPath: xcodePath)
        checks.append(.init(
            name: "Xcode toolchain",
            ok: xcodeOk,
            detail: xcodeOk ? "developer dir: \(xcodePath)" : "xcode-select -p failed - run `sudo xcode-select -s /Applications/Xcode.app`"
        ))

        // 2. xcodebuild -version
        let xcb = run("/usr/bin/env", args: ["xcodebuild", "-version"])
        let xcbOk = xcb.code == 0
        let xcbDetail = xcbOk ? xcb.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " · ") : "xcodebuild -version failed"
        checks.append(.init(name: "xcodebuild", ok: xcbOk, detail: xcbDetail))

        // 3. xcodegen
        let hasXg = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        checks.append(.init(
            name: "xcodegen",
            ok: hasXg,
            detail: hasXg ? "installed" : "missing - run `brew install xcodegen`"
        ))

        // 4. Simulator runtime available
        let simList = run("/usr/bin/env", args: ["xcrun", "simctl", "list", "devices", "available"])
        let hasIPhoneSim = simList.stdout.contains("iPhone") && !simList.stdout.contains("no devices")
        checks.append(.init(
            name: "iOS Simulator runtime",
            ok: hasIPhoneSim,
            detail: hasIPhoneSim ? "at least one iPhone simulator installed" :
                "no iPhone simulators found - Xcode → Settings → Platforms → install latest iOS runtime"
        ))

        // 5. Team ID (optional)
        if requireTeamId {
            let teamId = loadTeamId()
            checks.append(.init(
                name: "developer.teamId",
                ok: teamId != nil,
                detail: teamId.map { "present (\($0))" }
                    ?? "missing - not required for simulator builds, but needed to deploy to a physical device"
            ))
        }

        let allOk = checks.allSatisfy(\.ok)
        return IOSDoctorReport(allOk: allOk, checks: checks)
    }

    // Team ID + bundle prefix live in ~/Library/Application Support/Grux/config.json
    // as flat keys `developerTeamId` / `developerBundlePrefix` (matches GruxConfig
    // Codable). Fall back to legacy nested `developer.{teamId,bundlePrefix}` for
    // pre-migration configs.
    public static func loadTeamId() -> String? {
        guard let obj = loadConfigJSON() else { return nil }
        if let team = obj["developerTeamId"] as? String, !team.isEmpty { return team }
        if let dev = obj["developer"] as? [String: Any],
           let team = dev["teamId"] as? String, !team.isEmpty { return team }
        return nil
    }

    public static func loadBundlePrefix() -> String {
        if let obj = loadConfigJSON() {
            if let p = obj["developerBundlePrefix"] as? String, !p.isEmpty { return p }
            if let dev = obj["developer"] as? [String: Any],
               let p = dev["bundlePrefix"] as? String, !p.isEmpty { return p }
        }
        // Nothing configured. com.example is the reserved placeholder domain,
        // so a scaffold still produces a valid bundle id and the developer
        // sees immediately that it needs their own prefix.
        return "com.example"
    }

    private static func loadConfigJSON() -> [String: Any]? {
        let path = NSHomeDirectory() + "/Library/Application Support/Grux/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: - Internals

    private struct R { let code: Int32; let stdout: String; let stderr: String }
    private static func run(_ path: String, args: [String]) -> R {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(); let e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return R(code: -1, stdout: "", stderr: "\(error)") }
        p.waitUntilExit()
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return R(code: p.terminationStatus, stdout: out, stderr: err)
    }
}
