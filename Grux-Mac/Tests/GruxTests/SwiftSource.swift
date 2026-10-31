import Foundation

/// A Swift source read the way the compiler splits it, for the copy guards (wave 23 review:
/// each line-by-line guard was passed by a respelling). Comments are dropped; string literals
/// (`"..."`, `"""..."""`, raw `#"..."#`) are read whole as the words a person or the model
/// reads; the code around them is grouped into statements, so a literal joined with `+` over
/// lines, or a call split over lines, is one statement.
enum SwiftSource {
    struct Literal {
        /// The literal's words, escapes kept as written (`\n` stays two characters) and each
        /// interpolation read as one space.
        let text: String
        let line: Int
        /// The code inside each `\(...)`, in order.
        var interpolations: [String] = []
    }

    /// One call, `name(` to its own closing parenthesis, with the literals inside it.
    struct Call {
        let code: String
        let literals: [Literal]
        let line: Int
    }

    struct Statement {
        /// The statement's code with every literal's words taken out (interpolated code stays).
        let code: String
        let literals: [Literal]
        let line: Int
        /// Every literal's words in order, one space between.
        var words: String { literals.map(\.text).joined(separator: " ") }
        /// The literals as they read: neighbours the code joins with `+` (a value between them
        /// or not) are one phrase; a comma between them, as in an array, starts another.
        var phrases: [String] {
            let gaps = code.components(separatedBy: "\"\"")
            var out: [String] = []
            for (n, lit) in literals.enumerated() {
                let gap = n < gaps.count ? gaps[n] : ""
                if n > 0, gap.contains("+"), !gap.contains(","), !out.isEmpty {
                    out[out.count - 1] += " " + lit.text
                } else {
                    out.append(lit.text)
                }
            }
            return out
        }
    }

    /// The scanner reads UTF-8 bytes (every delimiter it looks for is ASCII), because a
    /// Character-by-Character scan took seven seconds over the sources in a debug build.
    /// A literal's place in the code is the byte 0x01, its index in digits, 0x01 again.
    private static let mark: UInt8 = 0x01

    static func statements(_ source: String) -> [Statement] {
        var scanner = Scanner(Array(source.utf8))
        scanner.scanCode(untilParen: false)
        return split(scanner, literals: scanner.literals)
    }

    /// Every call to `name` (any spacing before its parenthesis), read by its own parentheses,
    /// so a neighbour in the same group or statement is not part of it.
    static func calls(named name: String, in source: String) -> [Call] {
        var scanner = Scanner(Array(source.utf8))
        scanner.scanCode(untilParen: false)
        let code = scanner.code, lines = scanner.codeLines, word = Array(name.utf8)
        func isIdent(_ b: UInt8) -> Bool {
            b >= 0x80 || b == UInt8(ascii: "_") || (b >= 0x30 && b <= 0x39) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A)
        }
        var out: [Call] = []
        var p = 0
        while p + word.count <= code.count {
            guard (0..<word.count).allSatisfy({ code[p + $0] == word[$0] }), p == 0 || !isIdent(code[p - 1]) else { p += 1; continue }
            var k = p + word.count
            while k < code.count, isSpace(code[k]) { k += 1 }
            guard k < code.count, code[k] == UInt8(ascii: "(") else { p += 1; continue }
            k += 1
            var depth = 1
            while k < code.count, depth > 0 {
                if code[k] == UInt8(ascii: "(") { depth += 1 }
                if code[k] == UInt8(ascii: ")") { depth -= 1 }
                k += 1
            }
            let (plain, used) = unmark(code[p..<k], literals: scanner.literals)
            out.append(Call(code: plain, literals: used, line: lines[p]))
            p = k
        }
        return out
    }

    /// One view as SwiftUI builds it: the name, its arguments, every trailing closure
    /// (`{ ... } label: { ... }`) and its modifier chain (`.help("Delete")` on the next
    /// line), read by its own brackets, so a long action never pushes the label or the
    /// icon out of reach (wave 24: the line-window guard skipped a button 11 lines long).
    struct View {
        let code: String
        let literals: [Literal]
        let line: Int
        /// Byte offsets in the scanned code, to tell one view inside another.
        let span: Range<Int>
        /// The view itself: its name, arguments and trailing closures, not its modifier
        /// chain (wave 24: a dialog's chain ran on over a `.toolbar` of other buttons).
        let ownSpan: Range<Int>
    }

    /// Every `name(` or `name {` (an identifier on its own, so `DestructiveButton` is not
    /// `Button`), with `.name(` read the same way for a modifier such as `.confirmationDialog(`.
    static func views(named names: [String], in source: String) -> [View] {
        var scanner = Scanner(Array(source.utf8))
        scanner.scanCode(untilParen: false)
        let code = scanner.code, lines = scanner.codeLines
        func isIdent(_ b: UInt8) -> Bool {
            b >= 0x80 || b == UInt8(ascii: "_") || (b >= 0x30 && b <= 0x39) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A)
        }
        func skipSpace(_ k: Int) -> Int { var k = k; while k < code.count, isSpace(code[k]) { k += 1 }; return k }
        func balanced(_ k: Int, _ open: UInt8, _ close: UInt8) -> Int {
            var k = k + 1, depth = 1
            while k < code.count, depth > 0 {
                if code[k] == open { depth += 1 }
                if code[k] == close { depth -= 1 }
                k += 1
            }
            return k
        }
        func ident(_ k: Int) -> Int { var k = k; while k < code.count, isIdent(code[k]) { k += 1 }; return k }
        // Each whole identifier is looked up once (wave 24 round 4: trying names in turn at
        // every byte let `chip` hide `chipButton`, and took 74 s over the sources in debug).
        let wanted = Set(names.map { Array($0.utf8) })
        let funcWord = Array("func".utf8)
        var out: [View] = []
        var p = 0
        while p < code.count {
            guard isIdent(code[p]), p == 0 || !isIdent(code[p - 1]) else { p += 1; continue }
            let wordEnd = ident(p)
            guard wanted.contains(Array(code[p..<wordEnd])) else { p = wordEnd; continue }
            // A declaration (`func pill(icon: String = "trash", ...)`) is not a call.
            var back = p - 1
            while back >= 0, isSpace(code[back]) { back -= 1 }
            if back >= 3, Array(code[(back - 3)...back]) == funcWord, back - 4 < 0 || !isIdent(code[back - 4]) { p = wordEnd; continue }
            let word = code[p..<wordEnd]
            var k = skipSpace(p + word.count)
            guard k < code.count, code[k] == UInt8(ascii: "(") || code[k] == UInt8(ascii: "{") else { p += 1; continue }
            if code[k] == UInt8(ascii: "(") { k = balanced(k, UInt8(ascii: "("), UInt8(ascii: ")")) }
            var end = k
            // Trailing closures: `{ ... }`, then `label: { ... }` and the like.
            while true {
                var n = skipSpace(end)
                if n < code.count, code[n] != UInt8(ascii: "{"), isIdent(code[n]) {
                    let after = skipSpace(ident(n))
                    guard after < code.count, code[after] == UInt8(ascii: ":") else { break }
                    n = skipSpace(after + 1)
                }
                guard n < code.count, code[n] == UInt8(ascii: "{") else { break }
                end = balanced(n, UInt8(ascii: "{"), UInt8(ascii: "}"))
            }
            // The modifier chain: `.name` and its arguments. A modifier's trailing closure
            // (`.contextMenu { ... }`) holds other views, read on their own, so its body is
            // skipped, not read as this view's words.
            let ownEnd = end
            var segments = [p..<end]
            while true {
                let dot = skipSpace(end)
                guard dot < code.count, code[dot] == UInt8(ascii: "."), dot + 1 < code.count, isIdent(code[dot + 1]) else { break }
                var n = skipSpace(ident(dot + 1))
                if n < code.count, code[n] == UInt8(ascii: "(") { n = balanced(n, UInt8(ascii: "("), UInt8(ascii: ")")) }
                segments.append(dot..<n)
                let brace = skipSpace(n)
                if brace < code.count, code[brace] == UInt8(ascii: "{") { n = balanced(brace, UInt8(ascii: "{"), UInt8(ascii: "}")) }
                end = n
            }
            var plain = "", used: [Literal] = []
            for segment in segments {
                let (text, lits) = unmark(code[segment], literals: scanner.literals)
                plain += text + " "
                used += lits
            }
            out.append(View(code: plain, literals: used, line: lines[p], span: p..<end, ownSpan: p..<ownEnd))
            p += word.count
        }
        return out
    }

    /// The source with comments dropped and every literal read as `""`, so braces and
    /// words inside strings and comments are not code.
    static func plainCode(_ source: String) -> String {
        var scanner = Scanner(Array(source.utf8))
        scanner.scanCode(untilParen: false)
        return unmark(scanner.code[...], literals: scanner.literals).0
    }

    static func literals(_ source: String) -> [Literal] {
        var scanner = Scanner(Array(source.utf8))
        scanner.scanCode(untilParen: false)
        return scanner.literals
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// Code bytes with each literal's mark turned back into `""`, and the literals it held.
    private static func unmark(_ bytes: ArraySlice<UInt8>, literals: [Literal]) -> (String, [Literal]) {
        var plain: [UInt8] = [], used: [Literal] = []
        var k = bytes.startIndex
        while k < bytes.endIndex {
            if bytes[k] == mark {
                var n = k + 1, index = 0
                while n < bytes.endIndex, bytes[n] != mark { index = index * 10 + Int(bytes[n] - 0x30); n += 1 }
                used.append(literals[index])
                plain += Array("\"\"".utf8)
                k = n + 1
                continue
            }
            plain.append(bytes[k]); k += 1
        }
        return (String(decoding: plain, as: UTF8.self), used)
    }

    private struct Scanner {
        let s: [UInt8]
        var i = 0
        var line = 1
        var code: [UInt8] = []
        var codeLines: [Int] = []   // the line of each code byte
        var literals: [Literal] = []

        init(_ s: [UInt8]) { self.s = s }

        func at(_ k: Int) -> UInt8? { k < s.count ? s[k] : nil }

        mutating func advance() -> UInt8 {
            let b = s[i]; i += 1
            if b == 0x0A { line += 1 }
            return b
        }

        mutating func emit(_ b: UInt8, _ l: Int) { code.append(b); codeLines.append(l) }

        /// Code up to the end, or to the `)` closing an interpolation.
        mutating func scanCode(untilParen: Bool) {
            let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), hash = UInt8(ascii: "#"), quote = UInt8(ascii: "\"")
            var depth = 0
            while i < s.count {
                let b = s[i]
                if b == slash, at(i + 1) == slash {
                    while i < s.count, s[i] != 0x0A { i += 1 }
                    continue
                }
                if b == slash, at(i + 1) == star {
                    var nest = 0
                    repeat {
                        if s[i] == slash, at(i + 1) == star { nest += 1; i += 2; continue }
                        if s[i] == star, at(i + 1) == slash { nest -= 1; i += 2; continue }
                        _ = advance()
                    } while i < s.count && nest > 0
                    continue
                }
                var hashes = 0
                while at(i + hashes) == hash { hashes += 1 }
                if at(i + hashes) == quote {
                    i += hashes
                    scanString(hashes: hashes)
                    continue
                }
                if untilParen {
                    if b == UInt8(ascii: "(") { depth += 1 }
                    if b == UInt8(ascii: ")") {
                        if depth == 0 { i += 1; return }
                        depth -= 1
                    }
                }
                let l = line
                emit(advance(), l)
            }
        }

        /// A literal starting at its opening quote (after any `#`s).
        mutating func scanString(hashes: Int) {
            let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
            let startLine = line
            let multi = at(i + 1) == quote && at(i + 2) == quote
            i += multi ? 3 : 1
            let closer = [UInt8](repeating: quote, count: multi ? 3 : 1) + [UInt8](repeating: hash, count: hashes)
            let index = literals.count
            literals.append(Literal(text: "", line: startLine))
            emit(SwiftSource.mark, startLine)
            for d in String(index).utf8 { emit(d, startLine) }
            emit(SwiftSource.mark, startLine)
            var text: [UInt8] = []
            var interpolations: [String] = []
            while i < s.count {
                if i + closer.count <= s.count, (0..<closer.count).allSatisfy({ s[i + $0] == closer[$0] }) {
                    i += closer.count; break
                }
                if s[i] == backslash, (0..<hashes).allSatisfy({ at(i + 1 + $0) == hash }) {
                    let after = i + 1 + hashes
                    if at(after) == UInt8(ascii: "(") {
                        i = after + 1
                        text.append(0x20)
                        // A space each side, so neighbouring interpolations never run their
                        // names together ("\(a)\(b)" reads "a b", not "ab").
                        emit(0x20, line)
                        let before = code.count
                        scanCode(untilParen: true)
                        interpolations.append(SwiftSource.unmark(code[before...], literals: literals).0)
                        emit(0x20, line)
                        continue
                    }
                    text.append(advance())
                    for _ in 0..<hashes { text.append(advance()) }
                    if i < s.count { text.append(advance()) }
                    continue
                }
                text.append(advance())
            }
            literals[index] = Literal(text: String(decoding: text, as: UTF8.self), line: startLine, interpolations: interpolations)
        }
    }

    /// Statements: a newline outside parentheses and brackets ends one, unless the line ends
    /// with an operator or a comma, or the next one starts with `.`, `+`, `?` or `:`.
    private static func split(_ scanner: Scanner, literals: [Literal]) -> [Statement] {
        let code = scanner.code, lines = scanner.codeLines
        let ends = Set("+-*/=,&|?:".utf8), starts = Set(".+?:".utf8)
        var out: [Statement] = []
        var from = 0, depth = 0, k = 0
        var before: UInt8?   // the statement's last byte that is not white space
        func flush(_ to: Int) {
            let slice = code[from..<to]
            if slice.contains(where: { !isSpace($0) }) {
                let (plain, used) = unmark(slice, literals: literals)
                let first = slice.firstIndex(where: { !isSpace($0) }) ?? from
                out.append(Statement(code: plain, literals: used, line: lines[first]))
            }
        }
        while k < code.count {
            let b = code[k]
            if b == UInt8(ascii: "(") || b == UInt8(ascii: "[") { depth += 1 }
            if b == UInt8(ascii: ")") || b == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            if b == 0x0A, depth == 0 {
                var n = k + 1
                while n < code.count, isSpace(code[n]) { n += 1 }
                let continues = before.map(ends.contains) == true || (n < code.count && starts.contains(code[n]))
                if !continues { flush(k); from = k + 1; before = nil; k += 1; continue }
            }
            if !isSpace(b) { before = b }
            k += 1
        }
        flush(code.count)
        return out
    }

    /// Lowercased letter runs: every other character is a break, so "Jax-HQ", "HQ's",
    /// "Decisions\u{00A0}key" and "Decisions-key" read as their words.
    static func letterWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
}
