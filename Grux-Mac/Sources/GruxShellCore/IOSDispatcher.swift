import Foundation

// MARK: - IOSDispatcher
//
// Maps Claude tool_use calls (ios_doctor, ios_scaffold, ios_build_verify,
// ios_simulator_run) into IOS* modules and returns flat text suitable as a
// tool_result. Keeps all iOS-workflow logic in GruxShellCore so ShellDemo /
// integration tests / the Grux app can share one implementation.

public enum IOSDispatcher {

    public static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {

        case "ios_doctor":
            let needTeam = (input["require_team_id"] as? Bool) ?? false
            let report = await IOSDoctor.diagnose(requireTeamId: needTeam)
            return formatDoctor(report)

        case "ios_scaffold":
            return await handleScaffold(input: input)

        case "ios_build_verify":
            return await handleBuild(input: input)

        case "ios_simulator_run":
            return await handleSimulator(input: input)

        default:
            return "error: unknown ios tool '\(name)'"
        }
    }

    // MARK: - Scaffold

    private static func handleScaffold(input: [String: Any]) async -> String {
        let name = (input["project_name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { return "error: project_name required" }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "error: project_name must be alphanumeric (no spaces, dashes, or punctuation) - got '\(name)'"
        }
        let rootDir = (input["root_dir"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !rootDir.isEmpty else { return "error: root_dir required" }
        let prefix = (input["bundle_prefix"] as? String) ?? IOSDoctor.loadBundlePrefix()
        let bundleId = (input["bundle_id"] as? String) ?? "\(prefix).\(name.lowercased())"
        let minIOS = (input["min_ios"] as? String) ?? "17.0"
        let teamId = (input["team_id"] as? String) ?? IOSDoctor.loadTeamId()

        let featureNames = (input["features"] as? [String]) ?? ["chat", "voiceMemos", "tasks", "focusSummary"]
        let features = featureNames.compactMap { IOSFeature(rawValue: $0) }
        if features.isEmpty {
            return "error: features must contain at least one of: chat, voiceMemos, tasks, focusSummary"
        }

        let req = IOSScaffoldRequest(
            projectName: name,
            bundleId: bundleId,
            rootDir: rootDir,
            features: features,
            minIOS: minIOS,
            teamId: teamId
        )
        do {
            let r = try await IOSProjectGen.scaffold(req)
            return """
            ok: scaffolded \(name) at \(r.projectDir)
            xcodeproj: \(r.xcodeprojPath)
            scheme: \(r.scheme)
            bundle_id: \(bundleId)
            features: \(features.map(\.rawValue).joined(separator: ", "))
            files_written: \(r.filesCreated.count)
            next: call ios_build_verify with project_path=\(r.xcodeprojPath) scheme=\(r.scheme)
            """
        } catch let e as IOSToolError {
            return "error: \(e.description)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - Build verify

    private static func handleBuild(input: [String: Any]) async -> String {
        let proj = (input["project_path"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let scheme = (input["scheme"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !proj.isEmpty else { return "error: project_path required" }
        guard !scheme.isEmpty else { return "error: scheme required" }
        // Empty destination triggers auto-resolution inside IOSBuildVerify
        // (picks a concrete iPhone simulator UDID; generic/platform can hang
        // on Xcode 16 + iOS 26 SDKs).
        let dest = (input["destination"] as? String) ?? ""
        do {
            let r = try await IOSBuildVerify.build(projectPath: proj, scheme: scheme, destination: dest)
            // Keep the `.grux/project.json` marker fresh so the desktop
            // Projects tab surfaces the most recent build + app binary.
            // The .xcodeproj lives at `<projectDir>/<Scheme>.xcodeproj`, so
            // the project dir is the parent directory of that path.
            let projectDir = (proj as NSString).deletingLastPathComponent
            if r.success {
                LocalProjectMarker.update(projectDir: projectDir) { m in
                    m.lastBuildAt = Date()
                    m.lastAppPath = r.appPath ?? m.lastAppPath
                }
            }
            return formatBuild(r)
        } catch let e as IOSToolError {
            return "error: \(e.description)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - Simulator

    private static func handleSimulator(input: [String: Any]) async -> String {
        let appPath = (input["app_path"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let bundleId = (input["bundle_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !appPath.isEmpty else { return "error: app_path required (from ios_build_verify output)" }
        guard !bundleId.isEmpty else { return "error: bundle_id required" }
        let shotDir = (input["screenshot_dir"] as? String)
            ?? NSHomeDirectory() + "/Library/Application Support/Grux/ios-screenshots"
        let deviceName = (input["device_name"] as? String) ?? "iPhone 16"
        let opts = IOSSimulator.Options(deviceName: deviceName)
        do {
            let r = try await IOSSimulator.runAndScreenshot(
                appPath: appPath, bundleId: bundleId, screenshotDir: shotDir, opts: opts
            )
            // Record the latest screenshot on the matching Grux-scaffolded
            // project marker so the Projects tab can surface it inline.
            if let screenshot = r.screenshotPath,
               let hit = ProjectsIndex.findByBundleId(bundleId) {
                LocalProjectMarker.update(projectDir: hit.dir) { m in
                    m.lastScreenshotPath = screenshot
                }
            }
            return """
            ok: launched \(bundleId) on \(r.deviceName)
            device_id: \(r.deviceId)
            pid: \(r.pid.map(String.init) ?? "?")
            screenshot: \(r.screenshotPath ?? "(failed to capture)")
            log:
            \(r.log)
            """
        } catch let e as IOSToolError {
            return "error: \(e.description)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatters

    private static func formatDoctor(_ r: IOSDoctorReport) -> String {
        let lines = r.checks.map { c in
            "  \(c.ok ? "✅" : "❌") \(c.name) - \(c.detail)"
        }.joined(separator: "\n")
        let verdict = r.allOk ? "ok: all preflight checks passed" : "warn: some preflight checks failed"
        return """
        \(verdict)
        \(lines)
        """
    }

    private static func formatBuild(_ r: IOSBuildResult) -> String {
        if r.success {
            let app = r.appPath ?? "(unknown)"
            return """
            ok: build succeeded in \(String(format: "%.1f", r.durationSec))s (warnings: \(r.warnings.count))
            app_path: \(app)
            next: call ios_simulator_run with app_path=\(app)
            """
        }
        let errLines = r.errors.prefix(25).map { e -> String in
            let locator: String = {
                if let l = e.line, let c = e.column { return "\(e.file):\(l):\(c)" }
                return e.file
            }()
            return "  \(locator) - \(e.message)"
        }.joined(separator: "\n")
        let overflow = r.errors.count > 25 ? "\n  …(\(r.errors.count - 25) more errors)" : ""
        return """
        fail: build failed in \(String(format: "%.1f", r.durationSec))s · \(r.errors.count) errors · \(r.warnings.count) warnings
        errors:
        \(errLines)\(overflow)

        [last 2KB of build output]
        \(r.stdoutTail)

        next: fix each error above, then call ios_build_verify again. Grux's shell tool + file writes should handle this in-loop; do NOT stop until errors=0.
        """
    }
}
