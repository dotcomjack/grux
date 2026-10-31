import XCTest
@testable import Grux

/// W22-P3 item 5: four places told a person a Decisions key (Jev, from TypeSafe) makes
/// decisions "faster". Measured, it is the other way round: Jev answers in a median 368 ms,
/// this Mac in 3 ms (`FastLocalDecisionTests`, 603 real decisions), and Integrations quoted
/// a typical 216 ms beside local ones of about 4 ms. What the key adds is judging meaning
/// when the words do not match a phrase exactly. And the setup row sent people to Settings,
/// where no TypeSafe field exists; the key lives in Integrations.
@MainActor
final class DecisionKeyClaimTests: XCTestCase {

    private var everyKeyLine: [String] {
        [Setup.decisionsKeyWhy, HowItWorksCopy.decisionsKeyBody,
         SetupRequirement.keyTypesafe.remediation,
         TuningCopy.decisionsKey(saved: false, capped: false)]
    }

    func testNoLineSaysTheKeyMakesDecisionsFaster() {
        for line in everyKeyLine {
            XCTAssertFalse(line.lowercased().contains("faster"), line)
        }
    }

    func testEveryLineSaysWhatTheKeyAdds() {
        for line in everyKeyLine {
            XCTAssertTrue(line.contains("word for word"), "says nothing of what the key adds: \(line)")
        }
    }

    func testTheSetupRowPointsWhereTheKeyLives() {
        let line = SetupRequirement.keyTypesafe.remediation
        XCTAssertTrue(line.contains("in Integrations"), line)
        XCTAssertFalse(line.contains("in Settings"), line)
    }

    /// The class: no source line that names the key, Jev or TypeSafe calls it faster.
    func testNoSourceLineCallsTheKeyFaster() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Only files that could offend are read whole: one holding a word of every key
            // spelling the matcher reads and a speed stem. Plain `contains`, because a regex
            // over every source took six seconds.
            let low = text.lowercased()
            guard ["jev", "decision", "calls"].contains(where: low.contains) || (low.contains("type") && low.contains("safe")),
                  ["fast", "quick", "speed", "rapid", "sooner", "instant", "snappy"].contains(where: low.contains) else { continue }
            offenders += Self.callsTheKeyFaster(text).map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(offenders, [], "the key is not faster than deciding on this Mac")
        let contract = try String(contentsOf: root.appendingPathComponent("docs/contract.md"), encoding: .utf8)
        XCTAssertTrue(contract.contains(SetupRequirement.keyTypesafe.remediation),
                      "docs/contract.md quotes a different TypeSafe line")
    }

    /// Wave 23 round 1: the scan read one line at a time while this copy is strings joined
    /// with `+` over lines, matched "Decisions key" in one case only, and knew one speed word.
    func testTheFasterGuardCatchesEverySpelling() {
        let offenders = [
            "let s = \"... A Decisions key (Jev, from TypeSafe) \"\n    + \"makes them faster and surer.\"",
            #"let s = "Add a decision key for faster answers.""#,
            #"let s = "The Jev key gives quicker decisions.""#,
            #"let s = "TypeSafe speeds up every decision.""#,
            "let s = \"Decisions key: \" +\n    \"it makes those calls faster.\"",
            // Round 2: a multi-line literal, other speed words, other spellings of the key.
            "let s = \"\"\"\n    A Decisions key makes decisions faster.\n    \"\"\"",
            #"let s = "A Decisions key gives fast answers.""#,
            #"let s = "With Jev it answers quickly.""#,
            #"let s = "TypeSafe answers sooner.""#,
            #"let s = "Jev is speedier.""#,
            #"let s = "A Decisions API key makes it faster.""#,
            #"let s = "A Decisions-key makes it faster.""#,
            "let s = \"A Decisions\u{00A0}key makes it faster.\"",
            #"let s = "A Decisions key " + name + " makes them faster.""#,
            // Round 3: hard-wrapped prose, decimals, the plural, two words, "these calls".
            "let s = \"\"\"\n    A Decisions key makes\n    decisions faster.\n    \"\"\"",
            #"let s = "Jev (v1.2) answers faster.""#,
            #"let s = "Jev answers in 0.2 s, faster than before.""#,
            #"let s = "Decisions keys make decisions faster.""#,
            #"let s = "A Type Safe key makes decisions faster.""#,
            #"let s = "It makes these calls faster.""#,
            // Round 4: an abbreviation's full stop is not a sentence's end.
            #"let s = "A Decisions key (e.g. one from Integrations) makes decisions faster.""#,
            #"let s = "Jev, the cloud judge (vs. this Mac), is faster.""#,
        ]
        for code in offenders {
            XCTAssertFalse(Self.callsTheKeyFaster(code).isEmpty, "passed the faster guard: \(code)")
        }
        for code in [#"let s = "Deciding on this Mac is faster than a cloud call.""#,
                     #"let s = "Jev judges meaning when the words do not match word for word.""#,
                     "// A Decisions key is not faster.",
                     "let a = \"Jev judges meaning.\"\nlet b = \"This is faster.\"",
                     "let s = \"\"\"\n    Jev judges meaning.\n\n    Deciding here is faster.\n    \"\"\"",
                     // Round 5 P3: "devs." holds no "vs." abbreviation, so its full stop
                     // still ends the sentence.
                     #"let s = "Ships fast for devs. Jev judges meaning.""#] {
            XCTAssertEqual(Self.callsTheKeyFaster(code), [], code)
        }
    }

    /// Each statement's phrases read whole by `SwiftSource` (a `"""` literal, literals joined
    /// with `+` over lines, a value between them), cut into sentences only where a person reads
    /// one ending (`.`, `!` or `?` before a space or the end, a blank line; not a hard wrap or
    /// a decimal), each sentence's letter runs: one that names the key in any spelling and any
    /// speed word is refused.
    static func callsTheKeyFaster(_ text: String) -> [String] {
        let keys = ["decisions key", "decision key", "decisions keys", "decision keys",
                    "decisions api key", "decision api key", "typesafe", "type safe", "jev",
                    "makes those calls", "makes these calls"]
        let speeds = ["fast", "quick", "speed", "rapid", "sooner", "instant", "snappy"]
        var out: [String] = []
        for st in SwiftSource.statements(text) {
            // A phrase that holds none of the key's words is not read further (cheap first).
            let named = st.phrases.filter { p in
                let low = p.lowercased()
                return ["jev", "type", "decision", "calls"].contains(where: low.contains)
            }
            let sentences = named.flatMap { phrase -> [String] in
                // An abbreviation's full stop ends no sentence (round 4).
                // Whole words only, so "devs." holds no "vs.".
                let flat = phrase.lowercased()
                    .replacingOccurrences(of: #"(?<![a-z])(e)\.(g)\.|(?<![a-z])(i)\.(e)\.|(?<![a-z])(vs|etc|approx|cf)\."#,
                                          with: "$1$2$3$4$5", options: .regularExpression)
                    .replacingOccurrences(of: #"(\\n){2,}|\n\s*\n"#, with: ". ", options: .regularExpression)
                    .replacingOccurrences(of: #"\\[nrt]|\s+"#, with: " ", options: .regularExpression)
                return flat.replacingOccurrences(of: #"[.!?](\s|$)"#, with: "\u{1}", options: .regularExpression)
                    .components(separatedBy: "\u{1}")
            }
            for sentence in sentences {
                let runs = SwiftSource.letterWords(sentence)
                let spaced = " " + runs.joined(separator: " ") + " "
                guard keys.contains(where: { spaced.contains(" \($0) ") }),
                      runs.contains(where: { w in speeds.contains(where: w.hasPrefix) }) else { continue }
                out.append("line \(st.line): \(sentence.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out
    }
}
