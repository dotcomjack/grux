import XCTest
@testable import Grux

/// D115 item 2: Settings, Security said the URL guard "Denies private-IP ranges, localhost,
/// .local hosts" with no word of where, so a person who had just connected a local model
/// could read that Grux blocks its own Ollama. The guard stands only in front of the doors
/// that call `URLGuard.check`; the caption names exactly those and says the local model's
/// connection is not one of them.
final class URLGuardCaptionTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every Swift file under Sources (every module), but URLGuard.swift itself.
    private func sourceFiles() throws -> [URL] {
        let sources = root.appendingPathComponent("Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "swift" && url.lastPathComponent != "URLGuard.swift" {
            out.append(url)
        }
        return out
    }

    /// Which file each door's call lives in. Every guarded call must be one of these, so
    /// a guard call added anywhere else (a local model's path among them) fails here.
    private let doorFiles = ["open_url": "BrowserTool.swift", "research_fetch": "WebResearch.swift"]

    func test_theCaptionNamesEveryDoorTheGuardStandsIn() throws {
        var purposes = Set<String>()
        for url in try sourceFiles() {
            for call in URLGuardCallScan.calls(in: try String(contentsOf: url, encoding: .utf8)) {
                XCTAssertEqual(call.entry, "check", "\(url.lastPathComponent) calls URLGuard.\(call.entry); only check carries a purpose the caption can name")
                guard let purpose = call.purpose else {
                    XCTFail("\(url.lastPathComponent) calls URLGuard.\(call.entry) with no string literal purpose, so the Security caption cannot name the door"); continue
                }
                purposes.insert(purpose)
                XCTAssertEqual(doorFiles[purpose], url.lastPathComponent,
                               "the guard stands at \(url.lastPathComponent) (\(purpose)), a door the Security caption does not account for")
            }
        }
        XCTAssertFalse(purposes.isEmpty, "the scan found no URLGuard.check call; it is reading the wrong tree")
        XCTAssertEqual(Set(SecuritySettingsView.urlGuardDoors.map(\.purpose)), purposes,
                       "a door calls URLGuard.check that the Security caption does not name, or the caption names one that no longer does")
        XCTAssertEqual(Set(doorFiles.keys), purposes)
        let caption = SecuritySettingsView.urlGuardCaption
        for door in SecuritySettingsView.urlGuardDoors {
            XCTAssertTrue(caption.contains(door.words), "the caption does not say \"\(door.words)\"")
        }
    }

    /// W31 round 1: the scan read one line at a time and only a literal purpose, so a
    /// call split over lines, a first argument with a bracket in it, or a purpose in a
    /// variable added a door the caption never named, and the test stayed green.
    func test_theScanFindsEveryShapeOfCall() {
        typealias C = URLGuardCallScan.Call
        let table: [(String, [C])] = [
            (#"URLGuard.check(u, purpose: "a")"#, [C(entry: "check", purpose: "a")]),
            ("let d = URLGuard.check(\n    u,\n    purpose: \"b\")", [C(entry: "check", purpose: "b")]),
            (#"URLGuard.check(u.trimmingCharacters(in: .whitespaces), purpose: "c")"#, [C(entry: "check", purpose: "c")]),
            (#"URLGuard.check(u, purpose: Self.purpose)"#, [C(entry: "check", purpose: nil)]),
            (#"URLGuard.check(u, purpose: "a" + suffix)"#, [C(entry: "check", purpose: nil)]),
            (#"URLGuard.check(u, purpose: "a\(n)")"#, [C(entry: "check", purpose: nil)]),
            (#"if case .denied = URLGuard.evaluate(u) { }"#, [C(entry: "evaluate", purpose: nil)]),
            ("URLGuard .check (u, purpose: \"e\")", [C(entry: "check", purpose: "e")]),
            (#"let f = URLGuard.check; _ = f(u, "g")"#, [C(entry: "check", purpose: nil)]),
            (#"// URLGuard.check(u, purpose: "z")"#, []),
            ("/* URLGuard.check(u,\n purpose: \"z\") */", []),
            (#"let s = "see https://x.y"; URLGuard.check(s, purpose: "h")"#, [C(entry: "check", purpose: "h")]),
            (#"let c = URLGuardConfig(); let d: URLGuardDecision = .allowed"#, []),
            // W31 round 2: a multi-line or raw string with a lone quote inverted the
            // quote tracking, and nested block comments closed at the first `*/`.
            ("let help = \"\"\"\nType \"quit to exit\n\"\"\"\nlet u = \"https://x\"; let d = URLGuard.check(u, purpose: \"new\")",
             [C(entry: "check", purpose: "new")]),
            ("let re = #\"a\"b\"#\nlet u = \"http://h\"; URLGuard.check(u, purpose: \"new\")", [C(entry: "check", purpose: "new")]),
            ("let p = #\"C:\\\"#\nlet m = \"text/*\"\nlet d = URLGuard.check(u, purpose: \"new\")", [C(entry: "check", purpose: "new")]),
            ("let q = ##\"say \"#hi\"\"##\nURLGuard.check(u, purpose: \"new\")", [C(entry: "check", purpose: "new")]),
            ("/* a /* b */ URLGuard.check(u, purpose: \"z\") */", []),
        ]
        for (source, want) in table {
            XCTAssertEqual(URLGuardCallScan.calls(in: source), want, source)
        }
    }

    func test_theCaptionSaysTheLocalModelIsNotChecked() {
        let caption = SecuritySettingsView.urlGuardCaption
        XCTAssertTrue(caption.contains("Your local model's connection is not checked here"), caption)
        XCTAssertTrue(caption.contains("localhost"), "the caption stopped saying what it refuses")
    }

    func test_theLocalModelDoorsDoNotCallTheGuard() throws {
        let src = root.appendingPathComponent("Sources/Grux")
        var files = [src.appendingPathComponent("LocalLLM.swift")]
        for folder in ["Backend", "LocalModelCookbook"] {
            let dir = src.appendingPathComponent(folder)
            files += try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "OpenAICompatBackend.swift" }, "the local model's connection moved; point this test at it again")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "OllamaManager.swift" }, "the local model's connection moved; point this test at it again")
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(URLGuardCallScan.calls(in: text), [],
                           "\(url.lastPathComponent) now calls the URL guard, so the Security caption's promise about the local model is false")
        }
    }

    func test_thePaneDrawsTheCaption() throws {
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Security/SecuritySettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("Text(Self.urlGuardCaption)"), "the pane draws its own words instead of the tested caption")
        XCTAssertFalse(text.contains("Denies private-IP ranges"), "the old caption is back")
    }
}

/// Every call into `URLGuard` in a Swift source, comments left out: the member called
/// and, when the `purpose:` argument is one plain string literal, that string.
enum URLGuardCallScan {
    struct Call: Equatable { let entry: String; let purpose: String? }

    static func calls(in source: String) -> [Call] {
        let c = Array(stripComments(source))
        func isIdent(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        func skipSpace(_ k: inout Int) { while k < c.count, c[k].isWhitespace { k += 1 } }
        let word = Array("URLGuard")
        var out: [Call] = []
        var i = 0
        while i + word.count <= c.count {
            guard c[i] == word[0], Array(c[i..<i + word.count]) == word,
                  i == 0 || !isIdent(c[i - 1]),
                  i + word.count == c.count || !isIdent(c[i + word.count]) else { i += 1; continue }
            var k = i + word.count
            skipSpace(&k)
            guard k < c.count, c[k] == "." else { i = k; continue }
            k += 1
            skipSpace(&k)
            var name = ""
            while k < c.count, isIdent(c[k]) { name.append(c[k]); k += 1 }
            var after = k
            skipSpace(&after)
            // A member named but not called (`let f = URLGuard.check`) escapes any reading
            // of its purpose, so it counts as a call with none.
            guard after < c.count, c[after] == "(" else { out.append(Call(entry: name, purpose: nil)); i = k; continue }
            var depth = 0, inString = false, args = "", j = after
            while j < c.count {
                let ch = c[j]
                if inString {
                    if ch == "\\", j + 1 < c.count { args.append(ch); args.append(c[j + 1]); j += 2; continue }
                    if ch == "\"" { inString = false }
                } else if ch == "\"" {
                    inString = true
                } else if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                args.append(ch)
                j += 1
            }
            out.append(Call(entry: name, purpose: literalPurpose(args + ")")))
            i = j
        }
        return out
    }

    /// The `purpose:` argument when it is one plain string literal and nothing more.
    private static func literalPurpose(_ args: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"purpose:\s*"([^"\\]*)"\s*[,)]"#)
        let ns = args as NSString
        guard let m = re.firstMatch(in: args, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// The source with `//` and `/* */` comments (nested too) blanked. A plain string is
    /// kept as written, so a literal purpose can be read; a multi-line (`"""`) or raw
    /// (`#"..."#`) string becomes `""`, so a lone quote inside one cannot turn the rest of
    /// the file inside out. A purpose written as one of those is not a plain literal.
    private static func stripComments(_ source: String) -> String {
        let c = Array(source)
        // Compared in place: an array per character made this scan most of the
        // caption test's 16 s (T1 part 4).
        func at(_ i: Int, _ s: String) -> Bool {
            var k = i
            for ch in s {
                guard k < c.count, c[k] == ch else { return false }
                k += 1
            }
            return true
        }
        var out = "", i = 0
        while i < c.count {
            // Raw string: one or more `#`, then `"` or `"""`; ends at the same quote run
            // followed by the same number of `#`.
            if c[i] == "#" {
                var h = 0
                while i + h < c.count, c[i + h] == "#" { h += 1 }
                if at(i + h, "\"") {
                    let quotes = at(i + h, "\"\"\"") ? "\"\"\"" : "\""
                    let end = quotes + String(repeating: "#", count: h)
                    var k = i + h + quotes.count
                    while k < c.count, !at(k, end) { k += 1 }
                    out += "\"\""
                    i = min(c.count, k + end.count)
                    continue
                }
            }
            if at(i, "\"\"\"") {
                var k = i + 3
                while k < c.count, !at(k, "\"\"\"") { k += at(k, "\\") ? 2 : 1 }
                out += "\"\""
                i = min(c.count, k + 3)
                continue
            }
            if c[i] == "\"" {
                var k = i + 1
                while k < c.count, c[k] != "\"", c[k] != "\n" { k += c[k] == "\\" ? 2 : 1 }
                let stop = min(c.count, k + 1)
                out += String(c[i..<stop])
                i = stop
                continue
            }
            if at(i, "//") {
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            }
            if at(i, "/*") {
                var depth = 0
                while i < c.count {
                    if at(i, "/*") { depth += 1; i += 2 } else if at(i, "*/") { depth -= 1; i += 2; if depth == 0 { break } } else { i += 1 }
                }
                out.append(" ")
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out
    }
}
