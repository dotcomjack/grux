import XCTest

/// No file plays a sound except through `AudioOutput`.
///
/// Measured 2026-09-27: Grux had no global mute. Workflow chimes, wake chimes, macro
/// speech, `fire-speak`, notification sounds and Music control each reached the speaker
/// on their own, so `~/.grux/SILENT` could only be honored if every one of them was found
/// and gated by hand, and the next one added would not be. This scans every source file:
/// a sound API outside the facade fails here, so silent mode cannot be bypassed by a new
/// call site.
final class AudioOutputArchitectureTests: XCTestCase {

    private static let facade = "Sources/Grux/Audio/AudioOutput.swift"

    /// Backends behind the facade. Each may use only its own output API, and each must
    /// ask `AudioOutput` before it does.
    private static let backends: [(files: Set<String>, api: String)] = [
        (["Sources/Grux/Speaker.swift"], #"AVSpeechSynthesizer\b"#),
        (["Sources/Grux/SpeechEngine.swift"], #"AVAudioPlayerNode|mainMixerNode|outputNode"#),
        (["Sources/Grux/MusicKitPlayer.swift"], #"ApplicationMusicPlayer|SystemMusicPlayer|MPMusicPlayerController"#),
        (["Sources/Grux/MusicTool.swift", "Sources/Grux/AudioDucker.swift"], #"tell application "(Music|Spotify)""#),
    ]

    /// Only the facade may touch these.
    private static let facadeOnly: [String] = [
        #"\bNSSound\b"#,
        #"AudioServicesPlay"#,
        #"AVAudioPlayer(?!Node)"#,
        #"\bAV(Queue)?Player\("#,
        #"UNNotificationSound"#,
        #"NSSpeechSynthesizer"#,
        #"\bafplay\b"#,
        #"\bNSBeep\("#,
    ]

    /// `say` started as a command (`/usr/bin/say`, `sh -c "say ..."`, `env say`) plays
    /// aloud unless it writes to a file with `-o`.
    private static let sayCommand = #"["'](/usr/bin/)?say(\s|["'])"#

    /// The problems one line of code has, as the scan reports them.
    static func offenses(_ code: String) -> [String] {
        var out = facadeOnly.filter { code.range(of: $0, options: .regularExpression) != nil }
        // A notification's sound, or a foreground presentation that plays one,
        // unless the facade chose it. Asking permission to post with sound plays nothing.
        if code.range(of: #"\.sound\b"#, options: .regularExpression) != nil,
           !code.contains("requestAuthorization"), !code.contains("AudioOutput.") {
            out.append("sets a notification sound")
        }
        if code.range(of: sayCommand, options: .regularExpression) != nil, !code.contains("\"-o\"") {
            out.append("runs say without -o (plays aloud)")
        }
        return out
    }

    /// Code generated into other apps, never run by Grux; and the list of sound-making
    /// commands the shell doors refuse in silent mode, which names players to stop them.
    private static let exempt: Set<String> = [
        "Sources/GruxShellCore/IOSTemplates.swift",
        "Sources/GruxShellCore/ShellSilence.swift",
    ]

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// (relative path, line number, code with comments stripped)
    private func codeLines() throws -> [(String, Int, String)] {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var out: [(String, Int, String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if Self.exempt.contains(rel) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let code = raw.range(of: " //").map { String(raw[..<$0.lowerBound]) } ?? raw
                out.append((rel, i + 1, code))
            }
        }
        XCTAssertGreaterThan(out.count, 10_000, "the scan found almost no source, so it proves nothing")
        return out
    }

    private func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    func test_soundAPIsAppearOnlyInTheFacade() throws {
        var offenders: [String] = []
        for (file, n, code) in try codeLines() where file != Self.facade {
            for p in Self.offenses(code) {
                offenders.append("\(file):\(n) \(p): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "route these through AudioOutput so ~/.grux/SILENT holds")
    }

    /// RV25: the system beep and `say` run through a shell go red; `say -o` to a file does not.
    func test_theScanSeesTheBeepAndSayThroughAShell() {
        let planted = [
            "        NSBeep()",
            #"        p.arguments = ["-c", "say hello"]"#,
            #"        run("/bin/sh", ["-c", "say \(text)"])"#,
            #"        run("/usr/bin/env", ["say", text])"#,
            #"        run("/usr/bin/say", [text])"#,
            #"        shell("sh -c 'say done'")"#,
        ]
        for line in planted { XCTAssertFalse(Self.offenses(line).isEmpty, line) }
        let fine = [
            #"        runProcess("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, text])"#,
            #"        let hint = "What would you say to them?""#,
        ]
        for line in fine { XCTAssertEqual(Self.offenses(line), [], line) }
    }

    func test_eachOutputAPIAppearsOnlyInItsBackend() throws {
        var offenders: [String] = []
        let lines = try codeLines()
        for b in Self.backends {
            for (file, n, code) in lines where !b.files.contains(file) && file != Self.facade && matches(b.api, code) {
                offenders.append("\(file):\(n) uses /\(b.api)/, which belongs to \(b.files.sorted())")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func test_everyBackendAsksTheFacade() throws {
        for file in Self.backends.flatMap(\.files) {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(src.contains("AudioOutput.permit(") || src.contains("AudioOutput.isSilent"),
                          "\(file) plays audio without asking AudioOutput")
        }
    }
}
