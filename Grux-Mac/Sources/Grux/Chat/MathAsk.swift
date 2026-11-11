import Foundation

/// "What's 18% tip on $64.50?" (D155), worked out exactly with no model.
/// Sense pass 19 (11:10 AM Nov 4) asked Grux Local 2B exactly that and it
/// answered "$11.21"; the tip is $11.61. A person pays what Grux says, so a
/// sum is never left to a model's guess.
///
/// The grammar is closed and precision first (the W47 and W50 lesson): the
/// whole message must be one percent form or one sum of numbers, operators
/// and brackets, after an optional "what's" or "calculate". Anything else,
/// and anything that may not be a sum at all ("9/11", "24/7", "555-1234",
/// "2020-2024"), goes to the model, so a miss costs a model answer, never a
/// wrong number.
enum MathAsk {
    /// The largest number of digits in one number, and the size a result
    /// stays under, so Decimal's 38 digits always hold the exact answer.
    static let maxDigits = 15
    static let limit = Decimal(string: "1000000000000000")!
    /// Decimals shown before an answer reads "about".
    static let shownDecimals = 6

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let number = #"\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?"#
    private static let percent = #"(\d+(?:\.\d+)?)(?:\s*%|\s+percent)"#

    static func reply(for text: String) -> String? {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"[?.!=\s]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:(?:hey|hi|ok|okay)\s+)?(?:grux,?\s+)?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(?:what's|whats|what is|how much is|calculate|compute)\s+"#, with: "",
                                   options: .regularExpression)
        guard !s.isEmpty else { return nil }
        return percentReply(s) ?? expressionReply(s)
    }

    // MARK: Percent forms

    private static func percentReply(_ s: String) -> String? {
        if let m = match(#"^\#(percent) of (\#(number))( dollars)?$"#, s),
           let p = decimal(m[1]), let x = amount(m[2], dollars: !m[3].isEmpty) {
            let y = x.value * p / 100
            guard fits(y) else { return nil }
            let rounded = round(y, x.dollars ? 2 : shownDecimals)
            let about = !x.dollars && rounded != y ? "about " : ""
            let of = x.dollars ? money(x.value, true) : show(x.value, dollars: false)
            return "\(trim(m[1]))% of \(of) is \(about)\(show(rounded, dollars: x.dollars, cents: x.dollars))."
        }
        if let m = match(#"^(?:an? |the )?\#(percent) tip (?:on|for|of) (?:a |the )?(\#(number))( dollars)?(?: bill| check| tab)?$"#, s),
           let p = decimal(m[1]), let x = amount(m[2], dollars: !m[3].isEmpty) {
            return tip(percentText: m[1], p, x)
        }
        if let m = match(#"^(?:the )?tip (?:on|for) (?:a |the )?(\#(number))( dollars)?(?: bill| check| tab)? at \#(percent)$"#, s),
           let p = decimal(m[3]), let x = amount(m[1], dollars: !m[2].isEmpty) {
            return tip(percentText: m[3], p, x)
        }
        if let m = match(#"^\#(percent) off (\#(number))( dollars)?$"#, s),
           let p = decimal(m[1]), p <= 100, let x = amount(m[2], dollars: !m[3].isEmpty) {
            let off = round(x.value * p / 100, 2)
            let left = x.value - off
            guard fits(left) else { return nil }
            return "\(trim(m[1]))% off \(money(x.value, x.dollars)) is \(money(left, x.dollars)), so you save \(money(off, x.dollars))."
        }
        return nil
    }

    private static func tip(percentText: String, _ p: Decimal, _ x: (value: Decimal, dollars: Bool)) -> String? {
        let t = round(x.value * p / 100, 2)
        let total = x.value + t
        guard fits(total) else { return nil }
        let pct = trim(percentText)
        // Said aloud, 8, 11, 18 and 80 to 89 start with a vowel sound.
        let whole = pct.split(separator: ".").first.map(String.init) ?? pct
        let article = whole.hasPrefix("8") || whole == "11" || whole == "18" ? "An" : "A"
        return "\(article) \(pct)% tip on \(money(x.value, x.dollars)) is \(money(t, x.dollars)), so \(money(total, x.dollars)) in all."
    }

    // MARK: Sums

    private enum Token: Equatable {
        case num(Decimal, dollars: Bool, text: String)
        case op(Character)
        case open, close
    }

    private struct Value { var d: Decimal; var dollars: Bool }
    private enum Failure: Error { case divideByZero, notASum }

    private static func expressionReply(_ raw: String) -> String? {
        // Shapes that are usually not a sum: a hyphen or a slash typed tight
        // between two numbers (a phone number, a year span, a date, "24/7").
        if raw.range(of: #"\d-\d"#, options: .regularExpression) != nil { return nil }
        if raw.range(of: #"\d/\d+/\d"#, options: .regularExpression) != nil { return nil }
        if raw.range(of: #"^\$?\d+/\d+$"#, options: .regularExpression) != nil { return nil }
        var s = " " + raw + " "
        for (word, sign) in [(" multiplied by ", " * "), (" divided by ", " / "), (" plus ", " + "),
                             (" minus ", " - "), (" times ", " * ")] {
            s = s.replacingOccurrences(of: word, with: sign)
        }
        s = s.replacingOccurrences(of: #"(?<=[\d)])\s*x\s*(?=[\d($])"#, with: " * ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{00D7}", with: "*").replacingOccurrences(of: "\u{00F7}", with: "/")
        guard s.range(of: #"^[0-9.,$+\-*/() ]+$"#, options: .regularExpression) != nil,
              let tokens = tokenize(s),
              tokens.contains(where: { if case .op = $0 { return true }; return false }) else { return nil }
        var parser = Parser(tokens: tokens)
        let shown = echo(tokens)
        do {
            let v = try parser.expression()
            guard parser.atEnd, parser.binaryOps > 0, fits(v.d) else { return nil }
            let rounded = round(v.d, v.dollars ? 2 : shownDecimals)
            let about = rounded != v.d ? "about " : ""
            return "\(shown) is \(about)\(show(rounded, dollars: v.dollars, cents: v.dollars))."
        } catch Failure.divideByZero {
            return "\(shown) has no answer: nothing divides by zero."
        } catch {
            return nil
        }
    }

    private static func tokenize(_ s: String) -> [Token]? {
        var out: [Token] = []
        var rest = Substring(s)
        let num = try! NSRegularExpression(pattern: "^" + number)
        while let c = rest.first {
            if c == " " { rest = rest.dropFirst(); continue }
            if "+-*/".contains(c) { out.append(.op(c)); rest = rest.dropFirst(); continue }
            if c == "(" { out.append(.open); rest = rest.dropFirst(); continue }
            if c == ")" { out.append(.close); rest = rest.dropFirst(); continue }
            let str = String(rest)
            guard let m = num.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
                  let r = Range(m.range, in: str) else { return nil }
            let text = String(str[r])
            // A number runs into the next character only at a space, an
            // operator or a bracket ("1,2" and "3.4.5" are not numbers).
            let after = str[r.upperBound...].first
            if let after, !" +-*/()".contains(after) { return nil }
            guard let a = amount(text, dollars: false) else { return nil }
            out.append(.num(a.value, dollars: a.dollars, text: text))
            rest = rest.dropFirst(text.count)
        }
        return out
    }

    private struct Parser {
        let tokens: [Token]
        var i = 0
        var binaryOps = 0
        var atEnd: Bool { i == tokens.count }

        mutating func expression() throws -> Value {
            var v = try term()
            while i < tokens.count, case .op(let o) = tokens[i], o == "+" || o == "-" {
                i += 1; binaryOps += 1
                let r = try term()
                v = Value(d: o == "+" ? v.d + r.d : v.d - r.d, dollars: v.dollars || r.dollars)
                guard MathAsk.fits(v.d) else { throw Failure.notASum }
            }
            return v
        }

        mutating func term() throws -> Value {
            var v = try factor()
            while i < tokens.count, case .op(let o) = tokens[i], o == "*" || o == "/" {
                i += 1; binaryOps += 1
                let r = try factor()
                if o == "*" {
                    // Dollars times dollars is not an amount.
                    guard !(v.dollars && r.dollars) else { throw Failure.notASum }
                    v = Value(d: v.d * r.d, dollars: v.dollars || r.dollars)
                } else {
                    guard !(r.dollars && !v.dollars) else { throw Failure.notASum }
                    guard r.d != 0 else { throw Failure.divideByZero }
                    v = Value(d: v.d / r.d, dollars: v.dollars && !r.dollars)
                }
                guard MathAsk.fits(v.d) else { throw Failure.notASum }
            }
            return v
        }

        mutating func factor() throws -> Value {
            guard i < tokens.count else { throw Failure.notASum }
            switch tokens[i] {
            case .op("-"):
                i += 1
                var v = try factor()
                v.d = -v.d
                return v
            case .num(let d, let dollars, _):
                i += 1
                return Value(d: d, dollars: dollars)
            case .open:
                i += 1
                let v = try expression()
                guard i < tokens.count, tokens[i] == .close else { throw Failure.notASum }
                i += 1
                return v
            default:
                throw Failure.notASum
            }
        }
    }

    /// The sum as the person typed it, spaced, with × and ÷ for * and /.
    private static func echo(_ tokens: [Token]) -> String {
        var out = ""
        var previous: Token?
        for t in tokens {
            switch t {
            case .num(_, _, let text): out += text
            case .open: out += "("
            case .close: out += ")"
            case .op(let o):
                let unary: Bool
                switch previous {
                case nil, .op?, .open?: unary = true
                default: unary = false
                }
                let sign = o == "*" ? "\u{00D7}" : o == "/" ? "\u{00F7}" : String(o)
                out += unary ? sign : " \(sign) "
            }
            previous = t
        }
        return out
    }

    // MARK: Numbers

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    private static func decimal(_ text: String) -> Decimal? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= maxDigits else { return nil }
        return Decimal(string: text, locale: posix)
    }

    private static func amount(_ text: String, dollars: Bool) -> (value: Decimal, dollars: Bool)? {
        let bare = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard let d = decimal(bare), fits(d) else { return nil }
        return (d, dollars || text.hasPrefix("$"))
    }

    private static func fits(_ d: Decimal) -> Bool { !d.isNaN && abs(d) < limit }

    private static func round(_ d: Decimal, _ places: Int) -> Decimal {
        var input = d
        var out = Decimal()
        NSDecimalRound(&out, &input, places, .plain)
        return out
    }

    private static func trim(_ text: String) -> String {
        guard let d = decimal(text) else { return text }
        return show(d, dollars: false)
    }

    private static func money(_ d: Decimal, _ dollars: Bool) -> String { show(d, dollars: dollars, cents: true) }

    /// A number grouped by thousands, in cents when asked, with a dollar sign
    /// when the person gave one.
    private static func show(_ d: Decimal, dollars: Bool, cents: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = posix
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.minimumFractionDigits = cents ? 2 : 0
        f.maximumFractionDigits = cents ? 2 : shownDecimals
        f.roundingMode = .halfUp
        let text = f.string(from: d as NSDecimalNumber) ?? "\(d)"
        guard dollars else { return text }
        return text.hasPrefix("-") ? "-$" + text.dropFirst() : "$" + text
    }
}
