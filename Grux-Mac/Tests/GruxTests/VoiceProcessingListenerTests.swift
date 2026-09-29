import XCTest
@testable import Grux

/// Ambient listening must never turn on Apple's VoiceProcessingIO, and the
/// reason is an architectural fact rather than a preference.
///
/// Echo cancellation has exactly one job: take Grux's own spoken reply back
/// out of the microphone. Ambient listening does not need it, because it does
/// not have a microphone open while Grux speaks. `.gruxSpeechDidStart` calls
/// `suspendForSpeech()`, which calls `tearDownCapture()`, which stops the
/// engine and resets the rolling buffer; `resumeIfReady()` then waits 400ms
/// after the reply before reopening. Grux's voice cannot reach that engine.
///
/// The cost of enabling it anyway was measured on 2026-09-23 and is paid by
/// OTHER APPS, not by Grux: a separate process capturing from the same
/// microphone stopped receiving tap buffers at the instant VPIO started here
/// and never recovered. `wake.log` also carries 12 starts where voice
/// processing came up and delivered nothing, each one a 2.1s window where
/// Grux was deaf, followed by a restart.
///
/// NOT the reason, and corrected here so nobody restores it from an old note:
/// enabling VPIO does not put the Mac's output into a narrow-band call codec.
/// Measured the same day, a 12 kHz tone survived 73 dB above the silence floor
/// while VPIO ran, the output device stayed 48000 Hz 2ch 32bit lpcm, and a
/// playback-only process saw zero configuration changes. The old claim was
/// written from a code comment and had never been measured.
///
/// The two source scans at the bottom are the ones that actually hold the
/// fix. The behavioural tests prove the policy returns the right answer; only
/// a scan can prove a THIRD call site added later did not quietly opt back in,
/// and only a scan can catch the change that would invalidate the whole
/// argument: ambient deciding to keep listening while Grux speaks.
final class VoiceProcessingListenerTests: XCTestCase {

    // MARK: - The policy answer

    /// The case that matters: every condition that used to turn VPIO on is
    /// true (setting on, mic not whitelisted, output is speakers the mic can
    /// hear) and it still comes back off, purely because ambient drops the mic
    /// while Grux speaks.
    func testAmbientNeverEnablesVoiceProcessingEvenOnSpeakers() {
        let d = VoiceProcessingPolicy.shouldEnable(
            settingOn: true,
            micWhitelisted: false,
            output: .builtInSpeakers,
            refusedRecently: false,
            holdsMicWhileGruxSpeaks: false)
        XCTAssertFalse(d.enable,
            "ambient enabled voice processing on built-in speakers. It has no mic open while Grux speaks, so there is no echo to cancel, and the cost lands on every other app that is recording.")
        XCTAssertTrue(d.reason.contains("no echo to cancel"),
            "the WakeLog reason should say why, got: \(d.reason)")
    }

    /// Same, for the one route that used to be the loudest argument for
    /// keeping it: an unknown output, where the old policy deliberately left
    /// echo cancellation ON rather than risk Grux answering its own reply.
    /// That risk does not exist for a listener that is not listening.
    func testAmbientStaysOffEvenWhenTheOutputRouteIsUnknown() {
        let d = VoiceProcessingPolicy.shouldEnable(
            settingOn: true,
            micWhitelisted: false,
            output: .unknown,
            holdsMicWhileGruxSpeaks: false)
        XCTAssertFalse(d.enable,
            "an unknown output route kept VPIO on. Unknown exists to stop Grux hearing its OWN voice through speakers; ambient cannot hear its own voice at all.")
    }

    /// The other half of the contract. A listener that DOES hold the mic while
    /// Grux speaks still gets echo cancellation, so this change cannot be
    /// mistaken for switching the feature off everywhere.
    func testAListenerThatHoldsTheMicStillGetsEchoCancellation() {
        let d = VoiceProcessingPolicy.shouldEnable(
            settingOn: true,
            micWhitelisted: false,
            output: .builtInSpeakers,
            holdsMicWhileGruxSpeaks: true)
        XCTAssertTrue(d.enable,
            "a listener whose microphone is open while Grux speaks lost its echo cancellation. That one genuinely needs it.")
    }

    /// Default argument check. Every existing caller that does not pass the new
    /// parameter must keep its old behaviour, or this change silently disables
    /// echo cancellation on a path nobody reviewed.
    func testOmittingTheParameterKeepsTheOldBehaviour() {
        let d = VoiceProcessingPolicy.shouldEnable(
            settingOn: true, micWhitelisted: false, output: .builtInSpeakers)
        XCTAssertTrue(d.enable,
            "the default for holdsMicWhileGruxSpeaks changed behaviour for callers that do not pass it.")
    }

    /// The constant itself. Every other test here passes its own literal, so
    /// without this one somebody could flip `holdsMicWhileGruxSpeaks` back to
    /// true and the whole file would stay green while ambient quietly went
    /// back to enabling voice processing.
    func testAmbientDeclaresThatItDropsTheMicWhileGruxSpeaks() {
        XCTAssertFalse(AmbientListener.holdsMicWhileGruxSpeaks, """
            AmbientListener.holdsMicWhileGruxSpeaks is true, so ambient is asking for             echo cancellation again. That is only correct if ambient now keeps its             microphone open while Grux speaks. If it does, say so here and in             testAmbientStillStopsCapturingWhileGruxSpeaks; if it does not, this is a             regression that costs every other recording app its audio.
            """)
    }

    /// The user's off switch still outranks everything, including a listener
    /// that would otherwise qualify.
    func testTheSettingStillWinsAsAnOffSwitch() {
        let d = VoiceProcessingPolicy.shouldEnable(
            settingOn: false, micWhitelisted: false, output: .builtInSpeakers,
            holdsMicWhileGruxSpeaks: true)
        XCTAssertFalse(d.enable, "the Settings switch stopped being able to turn voice processing off.")
    }

    // MARK: - Source scans

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourcesRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Strip comments so a file that DOCUMENTS a call is not reported as
    /// making one. The sibling guard test learned this the hard way.
    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Text from the opening paren of a call up to the paren that balances it.
    private func balancedArguments(_ text: some StringProtocol) -> String {
        var depth = 0
        var out = ""
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(ch)
        }
        return out
    }

    /// Every `shouldEnable` call in AmbientListener must state that it does not
    /// hold the mic while Grux speaks. A third call site added later (there are
    /// two today: `startEngine` and `reconsiderVoiceProcessing`) that forgets
    /// this argument gets the permissive default and silently turns VPIO back
    /// on for ambient. That is exactly the shape of the bug this whole file
    /// exists for: the last one was a SECOND call site nobody wired up.
    func testEveryAmbientDecisionDeclaresItDropsTheMic() throws {
        let text = code(try source("Grux/Ambient/AmbientListener.swift"))
        let calls = text.components(separatedBy: "VoiceProcessingPolicy.shouldEnable").dropFirst()

        // Anti-vacuity control, first: a scanner that matches nothing would
        // certify this file as clean forever.
        XCTAssertGreaterThanOrEqual(calls.count, 2,
            "scanner found \(calls.count) shouldEnable call sites in AmbientListener; it should see at least startEngine and reconsiderVoiceProcessing. A scanner that finds nothing cannot fail.")

        for (i, call) in calls.enumerated() {
            // The argument list ends at the paren that BALANCES the opening
            // one, not at the first `)` in the text: the arguments contain
            // nested calls like `MicWhitelist.isWhitelisted(uid:)`, and
            // stopping at the first paren truncated every call site to two
            // arguments and reported both as offenders.
            let args = balancedArguments(call)
            XCTAssertTrue(args.contains("holdsMicWhileGruxSpeaks"),
                "AmbientListener shouldEnable call site \(i + 1) does not pass `holdsMicWhileGruxSpeaks`, so it gets the permissive default and turns voice processing back on for ambient. Arguments were:\n\(args)")
        }
    }

    /// The precondition the whole fix rests on. If ambient is ever changed to
    /// keep capturing while Grux speaks, then Grux WILL hear its own reply,
    /// echo cancellation stops being pointless, and turning it off becomes a
    /// real regression instead of a free win. This fails loudly at that moment
    /// rather than letting the two changes pass each other silently.
    func testAmbientStillStopsCapturingWhileGruxSpeaks() throws {
        let text = code(try source("Grux/Ambient/AmbientListener.swift"))

        XCTAssertTrue(text.contains(".gruxSpeechDidStart"),
            "AmbientListener no longer observes .gruxSpeechDidStart. Scanner is broken or the wiring is gone.")
        XCTAssertTrue(text.contains("suspendForSpeech"),
            "AmbientListener no longer has suspendForSpeech. The precondition for disabling voice processing is gone.")

        // Both halves existing is not enough: they have to be CONNECTED.
        // Measured while red-proving this file, deleting the call from inside
        // the observer left every other assertion here green, which is the
        // exact shape of a listener that keeps its microphone open through
        // Grux's reply while still claiming it does not.
        guard let observerRange = text.range(of: ".gruxSpeechDidStart") else {
            return XCTFail("no .gruxSpeechDidStart observer to check")
        }
        let observerBody = String(text[observerRange.upperBound...].prefix(240))
        XCTAssertTrue(observerBody.contains("suspendForSpeech"), """
            the .gruxSpeechDidStart observer no longer calls suspendForSpeech(), so ambient \
            keeps capturing while Grux speaks and WILL hear its own reply. Either restore the \
            call or set AmbientListener.holdsMicWhileGruxSpeaks back to true. Observer body read:
            \(observerBody)
            """)

        // suspendForSpeech must still tear the engine down, not merely flag.
        guard let body = text.range(of: "func suspendForSpeech()").map({ String(text[$0.upperBound...].prefix(400)) }) else {
            return XCTFail("could not read the body of suspendForSpeech()")
        }
        XCTAssertTrue(body.contains("tearDownCapture"), """
            suspendForSpeech() no longer calls tearDownCapture(), so ambient may now be \
            capturing while Grux speaks. If that is deliberate, ambient CAN hear its own \
            reply and `AmbientListener.holdsMicWhileGruxSpeaks` must become true again. \
            Body read:
            \(body)
            """)

        // And tearDownCapture must still drop what was already captured.
        guard let teardown = text.range(of: "func tearDownCapture(").map({ String(text[$0.upperBound...].prefix(700)) }) else {
            return XCTFail("could not read the body of tearDownCapture()")
        }
        XCTAssertTrue(teardown.contains("engine.stop()"),
            "tearDownCapture() no longer stops the engine.")
        XCTAssertTrue(teardown.contains("buffer.reset()"),
            "tearDownCapture() no longer resets the buffer, so audio captured just before Grux spoke can still reach a transcript.")
    }
}
