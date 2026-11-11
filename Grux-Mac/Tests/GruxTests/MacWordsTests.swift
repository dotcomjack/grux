import XCTest

/// D107 (sense pass 9, 2026-10-31): Grux is a Mac app, and its copy told people
/// to "tap" (Chat's "Nothing happens until you tap it.", Feature Review's
/// "without your tap", Speakers' "tap a speaker chip" under a header that says
/// "pick"). On a Mac a person clicks, approves or says yes. Every string literal
/// in the app module is read, comments out, so a new "tap" turns this red.
final class MacWordsTests: XCTestCase {
    /// Files whose "tap" is not a word to a person: the iOS automation scripts
    /// drive a simulator's `ui tap` command.
    private static let exempt: Set<String> = ["IOSDispatcherV2.swift"]

    /// Literals where "tap" is the right word, each with its reason: the file
    /// and a piece of the literal.
    private static let rightWord: [(file: String, piece: String)] = [
        ("PhonePairingView.swift", "on your iPhone and tap"),      // an iPhone is tapped
        ("CritiqueGate.swift", "tap targets"),                     // a web page's touch targets on a phone
        ("BriefingEngine.swift", "hand.tap"),                      // an SF Symbol name
        ("AmbientListener.swift", "tapping"),                      // a sound in a regex of noises
        ("VoiceInput.swift", "taps="),                             // audio engine taps, a log line
    ]

    private static func appSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" && !exempt.contains(url.lastPathComponent) {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    /// "tap", "taps", "tapped", "tapping" as a word, any case.
    static func saysTap(_ text: String) -> Bool {
        text.range(of: #"(?i)(?<![A-Za-z])tap(s|ped|ping)?(?![A-Za-z])"#, options: .regularExpression) != nil
    }

    func test_theMatcherReadsEveryForm() {
        for yes in ["Tap to expand", "until you tap it", "waiting on your tap", "tapped twice", "TAP HERE", "one-tap"] {
            XCTAssertTrue(Self.saysTap(yes), yes)
        }
        for no in ["tape", "taper", "stapler", "laptop", "Tapestry", "untapped"] {
            XCTAssertFalse(Self.saysTap(no), no)
        }
    }

    func test_noAppCopySaysTap() throws {
        let files = try Self.appSources()
        XCTAssertGreaterThan(files.count, 300, "the scan read almost nothing; the path is wrong")
        var hits: [String] = []
        for (name, text) in files {
            for lit in SwiftSource.literals(text) where Self.saysTap(lit.text)
                && !Self.rightWord.contains(where: { $0.file == name && lit.text.contains($0.piece) }) {
                hits.append("\(name):\(lit.line) \(lit.text.prefix(90))")
            }
        }
        XCTAssertEqual(hits, [], "say click, approve or yes on a Mac:\n" + hits.joined(separator: "\n"))
    }
}
