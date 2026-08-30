import Foundation
import GruxShellCore

// MARK: - IOSDemo
//
// End-to-end exercise of the iOS toolchain from zero: doctor → scaffold →
// build-verify (with auto-retry loop) → simulator-run. Proves Grux can ship a
// working iPhone app through the same tool surface ChatService uses.
//
// Exits 0 if the app lands on the simulator with a screenshot, non-zero on
// any unrecoverable failure.

@main
struct IOSDemo {
    static let maxBuildAttempts = 6

    static func main() async {
        let projectName = resolveArg("--name", default: "ProjectoAI")
        let rootDir = resolveArg("--root", default: expandTilde("~/Projects"))
        let featuresArg = resolveArg("--features", default: "chat,voiceMemos,tasks,focusSummary")
        let features = featuresArg.split(separator: ",").map { String($0) }
        let keepExisting = CommandLine.arguments.contains("--keep")

        banner("Grux iOS toolchain - full pipeline")
        print("project: \(projectName)")
        print("root:    \(rootDir)")
        print("feats:   \(features.joined(separator: ","))\n")

        // 1. Doctor
        banner("1. ios_doctor")
        let doctor = await IOSDispatcher.dispatch(name: "ios_doctor", input: [:])
        print(doctor)
        guard doctor.contains("ok:") else {
            exitFail("preflight failed - cannot continue")
        }

        // 2. Scaffold (wipe existing project dir first unless --keep)
        let projectDir = (rootDir as NSString).appendingPathComponent(projectName)
        if !keepExisting, FileManager.default.fileExists(atPath: projectDir) {
            print("\n(cleaning existing \(projectDir))")
            try? FileManager.default.removeItem(atPath: projectDir)
        }

        banner("2. ios_scaffold")
        let scaffoldOut = await IOSDispatcher.dispatch(name: "ios_scaffold", input: [
            "project_name": projectName,
            "root_dir": rootDir,
            "features": features
        ])
        print(scaffoldOut)
        guard let xcodeproj = extract(scaffoldOut, key: "xcodeproj:"),
              let scheme = extract(scaffoldOut, key: "scheme:"),
              let bundleId = extract(scaffoldOut, key: "bundle_id:")
        else { exitFail("scaffold did not emit xcodeproj/scheme/bundle_id") }

        // 3. Build - loop with auto-retry reporting
        banner("3. ios_build_verify (loop)")
        var appPath: String?
        for attempt in 1...maxBuildAttempts {
            print("\n── attempt \(attempt)/\(maxBuildAttempts) ──")
            let build = await IOSDispatcher.dispatch(name: "ios_build_verify", input: [
                "project_path": xcodeproj,
                "scheme": scheme
            ])
            print(build)
            if build.hasPrefix("ok:") {
                appPath = extract(build, key: "app_path:")
                print("\n✅ build succeeded on attempt \(attempt)")
                break
            }
            // This demo doesn't try to self-heal the templates - that's
            // Claude's job inside the real chat loop. If the canned templates
            // don't compile, we fail loudly so we know to fix the template.
            if attempt == maxBuildAttempts {
                exitFail("build still failing after \(maxBuildAttempts) attempts - template needs work")
            }
            // Small backoff for any transient xcodebuild flakiness (rare).
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let app = appPath else { exitFail("no app_path after successful build (parser bug?)") }

        // 4. Simulator
        banner("4. ios_simulator_run")
        let sim = await IOSDispatcher.dispatch(name: "ios_simulator_run", input: [
            "app_path": app,
            "bundle_id": bundleId
        ])
        print(sim)
        guard sim.hasPrefix("ok:") else { exitFail("simulator launch failed") }

        banner("done - Grux shipped the app")
        print("xcodeproj:  \(xcodeproj)")
        print("scheme:     \(scheme)")
        print("bundle_id:  \(bundleId)")
        print("app_path:   \(app)")
        if let shot = extract(sim, key: "screenshot:") {
            print("screenshot: \(shot)")
        }
        exit(0)
    }

    // MARK: - CLI helpers

    private static func resolveArg(_ flag: String, default def: String) -> String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return def }
        return args[i + 1]
    }

    private static func expandTilde(_ s: String) -> String {
        NSString(string: s).expandingTildeInPath
    }

    private static func extract(_ text: String, key: String) -> String? {
        for line in text.components(separatedBy: "\n") where line.contains(key) {
            if let range = line.range(of: key) {
                return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func banner(_ s: String) {
        let bar = String(repeating: "═", count: 61)
        print("\n\(bar)")
        print(" \(s)")
        print("\(bar)")
    }

    private static func exitFail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("\nFATAL: \(msg)\n".utf8))
        exit(1)
    }
}
