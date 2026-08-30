import Foundation

// MARK: - IOSSimulator
//
// Orchestrates `xcrun simctl` to: pick a simulator, boot it, install an .app,
// launch by bundle ID, and capture a screenshot. The flow is idempotent and
// tolerant - "already booted" / "already installed" do not count as errors.

public enum IOSSimulator {

    public struct Options: Sendable {
        public var deviceName: String        // "iPhone 16"
        public var runtimePrefix: String     // "iOS 18" - match simctl runtime key prefix
        public var waitForLaunchSec: Double

        public init(deviceName: String = "iPhone 16",
                    runtimePrefix: String = "iOS ",
                    waitForLaunchSec: Double = 4.0) {
            self.deviceName = deviceName
            self.runtimePrefix = runtimePrefix
            self.waitForLaunchSec = waitForLaunchSec
        }
    }

    public static func runAndScreenshot(appPath: String,
                                        bundleId: String,
                                        screenshotDir: String,
                                        opts: Options = Options()) async throws -> IOSSimulatorResult {
        var log = ""
        func append(_ line: String) { log += line + "\n" }

        let fm = FileManager.default
        guard fm.fileExists(atPath: appPath) else {
            throw IOSToolError.simulatorFailed("app not found at \(appPath)")
        }

        // 1. Pick a device
        let device = try await pickDevice(opts: opts, log: { append($0) })
        append("device: \(device.name) (\(device.udid))   state: \(device.state)")

        // 2. Boot if needed (ignore "Unable to boot device in current state: Booted")
        if device.state.lowercased() != "booted" {
            let r = try await simctl(["boot", device.udid])
            append("boot: exit=\(r.code)")
            if r.code != 0 && !r.combined.lowercased().contains("already booted") {
                throw IOSToolError.simulatorFailed("simctl boot failed: \(r.combined)")
            }
        } else {
            append("boot: already booted")
        }

        // Open Simulator.app so the user can SEE it - otherwise the sim runs headless
        // which makes the "I saw it work" moment weaker.
        _ = try? await runProcess(path: "/usr/bin/open", args: ["-a", "Simulator"])

        // 3. Install
        let inst = try await simctl(["install", device.udid, appPath])
        append("install: exit=\(inst.code)")
        guard inst.code == 0 else {
            throw IOSToolError.simulatorFailed("simctl install failed: \(inst.combined)")
        }

        // 4. Launch
        let launch = try await simctl(["launch", device.udid, bundleId])
        append("launch: exit=\(launch.code) \(launch.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard launch.code == 0 else {
            throw IOSToolError.simulatorFailed("simctl launch failed: \(launch.combined)")
        }
        // Parse "<bundleId>: <pid>" output for the pid
        var launchedPid: Int?
        if let tail = launch.combined.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
            launchedPid = Int(tail)
        }

        // 5. Wait a beat so the app can draw its first frame, then screenshot.
        try? await Task.sleep(nanoseconds: UInt64(opts.waitForLaunchSec * 1_000_000_000))
        try? fm.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        let shot = (screenshotDir as NSString)
            .appendingPathComponent("\(bundleId)-\(Int(Date().timeIntervalSince1970)).png")
        let shotR = try await simctl(["io", device.udid, "screenshot", shot])
        append("screenshot: exit=\(shotR.code) → \(shot)")

        return IOSSimulatorResult(
            deviceId: device.udid,
            deviceName: device.name,
            bundleId: bundleId,
            installed: inst.code == 0,
            launched: launch.code == 0,
            pid: launchedPid,
            screenshotPath: fm.fileExists(atPath: shot) ? shot : nil,
            log: log
        )
    }

    // MARK: - Device discovery

    private struct Device { let name: String; let udid: String; let state: String }

    private static func pickDevice(opts: Options, log: (String) -> Void) async throws -> Device {
        let r = try await simctl(["list", "devices", "available", "-j"])
        guard r.code == 0 else {
            throw IOSToolError.simulatorFailed("simctl list failed: \(r.combined)")
        }
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = obj["devices"] as? [String: Any]
        else {
            throw IOSToolError.simulatorFailed("simctl list JSON parse failed")
        }

        // First pass: device name + runtime prefix match
        var best: Device?
        for (runtime, raw) in devicesByRuntime {
            let isIOSRuntime = runtime.contains("SimRuntime.iOS") || runtime.contains("iOS")
            guard isIOSRuntime, let list = raw as? [[String: Any]] else { continue }
            for d in list {
                guard
                    let name = d["name"] as? String,
                    let udid = d["udid"] as? String,
                    let isAvail = d["isAvailable"] as? Bool, isAvail
                else { continue }
                let state = (d["state"] as? String) ?? "Shutdown"
                // Prefer exact match on opts.deviceName. Fall back to any iPhone.
                if name == opts.deviceName {
                    if state.lowercased() == "booted" {
                        return Device(name: name, udid: udid, state: state)
                    }
                    if best == nil { best = Device(name: name, udid: udid, state: state) }
                }
            }
        }
        if let b = best { return b }

        // Second pass: any iPhone available
        for (_, raw) in devicesByRuntime {
            if let list = raw as? [[String: Any]] {
                for d in list {
                    guard
                        let name = d["name"] as? String,
                        let udid = d["udid"] as? String,
                        let isAvail = d["isAvailable"] as? Bool, isAvail,
                        name.hasPrefix("iPhone")
                    else { continue }
                    let state = (d["state"] as? String) ?? "Shutdown"
                    log("falling back to \(name)")
                    return Device(name: name, udid: udid, state: state)
                }
            }
        }

        throw IOSToolError.simulatorFailed("no available iPhone simulator found. Install one via Xcode → Settings → Platforms.")
    }

    // MARK: - Process helpers

    private struct ProcResult { let code: Int32; let stdout: String; let stderr: String; let combined: String }

    private static func simctl(_ args: [String]) async throws -> ProcResult {
        try await runProcess(path: "/usr/bin/env", args: ["xcrun", "simctl"] + args)
    }

    private static func runProcess(path: String, args: [String]) async throws -> ProcResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let oP = Pipe(); let eP = Pipe()
        proc.standardOutput = oP
        proc.standardError = eP
        try proc.run()
        proc.waitUntilExit()
        let o = String(data: oP.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: eP.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcResult(code: proc.terminationStatus, stdout: o, stderr: e, combined: o + e)
    }
}
