import XCTest

/// Every code path that switches macOS into VoiceProcessingIO must consult the
/// user's setting first. This proves it, at every call site, forever.
///
/// Why a source scan rather than a behavioural test: the bug this guards
/// against is not a wrong value, it is a SECOND CALL SITE that nobody wired to
/// the switch. That is exactly what shipped. `VoiceInput` read
/// `config.premiumNoiseCancellation` and `AmbientListener` did not, so turning
/// voice processing off in Settings quieted dictation and left ambient mode
/// still forcing the whole system output chain into the narrow-band call
/// codec. Every unit test passed throughout, because each one exercised the
/// path that was correct. A test that asserts the flag's value can only prove
/// the switch is in the right position; it cannot prove the switch is wired to
/// everything it claims to control.
///
/// The stakes are not cosmetic. Enabling VPIO degrades ALL system output
/// (Music, Safari, YouTube, Netflix) to a narrow-band communications codec for
/// as long as the engine runs. A user who taps the mic once while music is
/// playing hears their audio quality drop and has no idea Grux did it.
final class VoiceProcessingGuardTests: XCTestCase {

    /// The call that flips the HAL into voice-chat mode.
    private static let enableCall = "setVoiceProcessingEnabled(true)"

    /// The setting every such call must consult.
    private static let requiredGuard = "premiumNoiseCancellation"

    /// How far back a guard may sit from the call it protects. Generous on
    /// purpose: both real call sites bind the flag to a local a few lines
    /// above the `do` block, and tightening this would fail correct code.
    private static let lookbackLines = 25

    /// Files allowed to call it unguarded, each with the reason it is safe.
    ///
    /// `SmokeTest.swift` probes the API on a DISPOSABLE `AVAudioEngine` to
    /// report whether this Mac supports voice processing at all, then
    /// immediately calls `setVoiceProcessingEnabled(false)` to put the HAL
    /// back. It never touches the capture path and never runs while the user
    /// is listening to anything, so gating it on the setting would only make
    /// the diagnostic lie about the hardware's capability.
    private static let exempt: Set<String> = ["SmokeTest.swift"]

    /// Tests/GruxTests/<this file> -> up three -> Grux-Mac.
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private struct CallSite {
        let file: String
        let line: Int
        let guarded: Bool
    }

    /// Comment lines are stripped before matching. `MicDevices.swift` explains
    /// this whole mechanism in its header and names the call in prose; without
    /// stripping, the file that documents the hazard is reported as causing it.
    private func callSites() throws -> [CallSite] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourcesRoot,
                                         includingPropertiesForKeys: [.isRegularFileKey]) else {
            XCTFail("could not walk \(sourcesRoot.path)")
            return []
        }
        var found: [CallSite] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let code = raw.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                guard code.contains(Self.enableCall) else { continue }
                let from = max(0, i - Self.lookbackLines)
                let window = lines[from...i].joined(separator: "\n")
                found.append(CallSite(file: url.lastPathComponent,
                                      line: i + 1,
                                      guarded: window.contains(Self.requiredGuard)))
            }
        }
        return found
    }

    /// Anti-vacuity control, and it runs FIRST for a reason. A scanner that
    /// finds nothing passes the real test below silently and forever. This
    /// pins the call sites that are known to exist, so a regex that stops
    /// matching fails here loudly instead of certifying the tree as clean.
    func testScannerActuallyFindsTheKnownCallSites() throws {
        let sites = try callSites()
        XCTAssertGreaterThanOrEqual(sites.count, 3,
            "scanner found only \(sites.count) call sites; it should see VoiceInput, AmbientListener and the SmokeTest probe. A scanner that finds nothing cannot fail.")
        let files = Set(sites.map(\.file))
        XCTAssertTrue(files.contains("VoiceInput.swift"), "scanner lost VoiceInput.swift. Found: \(files.sorted())")
        XCTAssertTrue(files.contains("AmbientListener.swift"), "scanner lost AmbientListener.swift. Found: \(files.sorted())")
    }

    /// The invariant itself.
    func testEveryVoiceProcessingEnableConsultsTheUserSetting() throws {
        let offenders = try callSites().filter { !$0.guarded && !Self.exempt.contains($0.file) }
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) call site(s) enable VoiceProcessingIO without consulting \
            `\(Self.requiredGuard)` within \(Self.lookbackLines) lines:
            \(offenders.map { "  \($0.file):\($0.line)" }.joined(separator: "\n"))
            Enabling VPIO drops ALL system audio to a narrow-band call codec. Either read the \
            setting before this call, or add the file to `exempt` with the reason it is safe.
            """)
    }

    /// Keeps the exemption list honest. An exemption for a file that no longer
    /// calls the API is dead permission, and dead permission is how a future
    /// unguarded call site gets waved through by a line nobody re-read.
    func testExemptionsAreStillEarned() throws {
        let callers = Set(try callSites().map(\.file))
        for name in Self.exempt {
            XCTAssertTrue(callers.contains(name),
                "\(name) is exempt but no longer calls \(Self.enableCall). Remove the exemption.")
        }
    }
}
