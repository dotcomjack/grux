import XCTest
@testable import Grux

/// D81 (sense pass 6, `agents-1.png`): Agents showed "$0.0000 of $5.00". Every amount in the
/// pane reads like money, through one formatter, the one the Usage card already uses.
final class AgentsMoneyTests: XCTestCase {

    func testAmountsReadLikeMoneyOnEveryEdge() {
        let cases: [(Double, String)] = [
            (0, "$0.00"), (-0.5, "$0.00"),
            (0.0001, "under $0.01"), (0.0099, "under $0.01"),
            (0.01, "$0.01"), (0.0149, "$0.01"), (0.015, "$0.01"),
            (1.2345, "$1.23"), (4.999, "$5.00"), (5, "$5.00"), (12.5, "$12.50"),
        ]
        for (usd, shown) in cases {
            XCTAssertEqual(AgentsView.money(usd), shown, "\(usd)")
        }
    }

    /// W22-P3 item 6: 5.004 and 4.996 both round to "$5.00", so an overrun read "$5.00 of $5.00",
    /// as if on budget. Spent strictly over the budget always says so, on, under and over the edge.
    func testAnOverrunNeverReadsAsOnBudget() {
        let cases: [(Double, Double, String)] = [
            (0, 5, "$0.00 of $5.00"),
            (0.0034, 5, "under $0.01 of $5.00"),
            (4.996, 5, "$5.00 of $5.00"),
            (5, 5, "$5.00 of $5.00"),
            (5.004, 5, "$5.00, over the $5.00 budget"),
            (5.01, 5, "$5.01, over the $5.00 budget"),
            (12.5, 5, "$12.50, over the $5.00 budget"),
            (0.004, 0, "under $0.01, over the $0.00 budget"),
        ]
        for (spent, budget, shown) in cases {
            XCTAssertEqual(AgentsView.spentOfBudget(spent, budget), shown, "\(spent) of \(budget)")
        }
    }

    /// W22-P3 item 7: a garbage amount read "$nan" or "$inf". It reads as no amount.
    func testANonFiniteAmountNeverReadsAsDigits() {
        for usd in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(AgentsView.money(usd), "$0.00", "\(usd)")
            XCTAssertNil(DecisionUsageSummary.money(usd), "\(usd)")
        }
    }

    /// Every "spent of budget" line in the pane goes through `spentOfBudget`, so none can
    /// round an overrun back onto the budget by hand.
    func testThePaneNeverJoinsSpentAndBudgetByHand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in Self.agentSources {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/Grux/\(name)"), encoding: .utf8)
            XCTAssertEqual(Self.joinsByHand(text, file: name), [],
                           "\(name): a spent-of-budget line built by hand; use AgentsView.spentOfBudget")
        }
    }

    func testTheAgentsPaneFormatsNoAmountByHand() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/AgentsView.swift")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for line in lines where line.contains("String(format:") {
            XCTAssertFalse(line.contains("%.4f") || line.contains("%.2f"),
                           "an amount formatted by hand, outside AgentsView.money: \(line)")
        }
    }

    /// W22-P3 item 7: the tool results and chat hand-offs Agents gives the model said
    /// "$0.0034 / $5.00" and "spent=$0.0000 of $5.00" while the pane said "under $0.01 of $5.00",
    /// so a reply could quote a different amount than the pane. Every dollar amount in the
    /// agent sources goes through `AgentsView.money` or `AgentsView.spentOfBudget`.
    func testNoAgentSourceFormatsADollarAmountByHand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in Self.agentSources {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/Grux/\(name)"), encoding: .utf8)
            XCTAssertEqual(Self.amountsByHand(text, file: name), [], "\(name): a dollar amount formatted by hand")
        }
    }

    // MARK: The guards' own matchers (wave 23 review: each was bypassed by a respelling)

    private static let agentSources = ["AgentsView.swift", "AgentTools.swift", "AgentService.swift"]

    /// Wave 23 round 1: the scan read only `$\(String(format: "%.Nf"` and `"$%.Nf"` on one
    /// line. Every spelling that puts a dollar sign beside a number by hand is caught.
    func testTheAmountGuardCatchesEverySpelling() {
        let offenders = [
            #"let s = "$" + String(format: "%.2f", x)"#,
            #"let s = String(format: "budget=$%.2f", x)"#,
            #"let s = "budget=$\(budget)""#,
            #"let s = "$\(String(format: "%0.2f", x))""#,
            #"let s = "$\(String(format: "%.2lf", x))""#,
            "let s = \"$\\(String(\n    format: \"%.4f\", x))\"",
            #"let s = String(format: "%.3f", x) + "$""#,
            // Round 2: one space, a longer literal, Foundation's currency style, a raw string,
            // and "$" kept in a value.
            #"let s = "$ \(x)""#,
            #"let s = "spent=$" + "\(x)""#,
            #"let s = "budget=$" + String(x)"#,
            #"let s = x.formatted(.currency(code: "USD"))"#,
            #"let s = "\(x, format: .currency(code: "USD"))""#,
            ##"let s = #"$\#(x)"#"##,
            #"let s = "$".appending(String(x))"#,
            #"let s = ["$", String(x)].joined()"#,
            #"let d = "$""#,
            // Round 3: "$" as an escape, a raw amount, a star precision, the capitalised style,
            // the glyph's shape with an amount in it.
            #"let s = "spent=\u{24}\(x)""#,
            #"let s = "budget_usd=\(budget)""#,
            #"let s = "\(String(format: "%.*f", 2, x)) USD""#,
            #"let s = x.formatted(FloatingPointFormatStyle<Double>.Currency(code: "USD"))"#,
            #"case .usage: return "$5.00""#,
            #"let s = "Cost: \(spent) of \(AgentsView.money(job.budgetUSD))""#,
            // Round 4: a raw amount read outside an interpolation, however it is made text.
            #"lines.append("spent: " + String(j.spentUSD))"#,
            #"let s = String(job.spentUSD) + " USD""#,
            #"Text(job.spentUSD, format: .number)"#,
            #"Text(job.budgetUSD.formatted())"#,
            #"let s = job.spentUSD.formatted(.number.rounded(increment: 0.01))"#,
            #"Text("\(job.total, specifier: "%.4f")")"#,
            // Round 5: formatted after an expression, or kept as a number under a new name.
            "let left = (job.budgetUSD - job.spentUSD).formatted()\nText(\"\\(left) left\")",
            #"let shown = job.spentUSD.rounded().formatted()"#,
            #"let s = Decimal(job.spentUSD).formatted()"#,
            "let left = job.budgetUSD - job.spentUSD\nlines.append(\"left: \\(left)\")",
            // Round 6: an amount held by a computed property or a helper.
            "private var remaining: Double { max(0, job.budgetUSD - job.spentUSD) }\nText(\"\\(remaining) left\")",
            "private var remaining: Double {\n    max(0, job.budgetUSD - job.spentUSD)\n}\nlines.append(\"left: \\(remaining)\")",
            "func remaining() -> Double { job.budgetUSD - job.spentUSD }\nlet s = \"\\(remaining())\"",
            // Round 7: an amount chosen by a ternary, or summed past a filter's comparison.
            "let overBy = job.spentUSD > job.budgetUSD ? job.spentUSD - job.budgetUSD : 0\nlines.append(\"over by \\(overBy)\")",
            "let remaining = jobs.filter { $0.status != .done }.reduce(0) { $0 + $1.budgetUSD }\nText(\"\\(remaining) left\")",
            "var overBy: Double { job.spentUSD > job.budgetUSD ? job.spentUSD - job.budgetUSD : 0 }\nText(\"\\(overBy)\")",
            // Round 8: a return inside a one-line if, an else, a case; an if-expression.
            "private var overBy: Double {\n    if job.spentUSD > job.budgetUSD { return job.spentUSD - job.budgetUSD }\n    return 0\n}\nText(\"over by \\(overBy)\")",
            "func overBy() -> Double {\n    switch state {\n    case .over: return job.spentUSD - job.budgetUSD\n    default: return 0\n    }\n}\nlet s = \"\\(overBy())\"",
            "let overBy = if job.spentUSD > job.budgetUSD { job.spentUSD - job.budgetUSD } else { 0 }\nText(\"\\(overBy)\")",
            // Round 9: a return past a closure or over lines; an if or switch over lines.
            "var remaining: Double {\n    return jobs.filter { $0.status != .done }.reduce(0) { $0 + $1.budgetUSD }\n}\nText(\"\\(remaining) left\")",
            "var remaining: Double { return jobs.filter { $0.status != .done }.reduce(0) { $0 + $1.budgetUSD } }\nText(\"\\(remaining) left\")",
            "func limit(for id: String) -> Double {\n    return jobs.first { $0.id == id }?.budgetUSD ?? 0\n}\nText(\"\\(limit(for: x))\")",
            "var total: Double {\n    return jobs\n        .filter(\\.isActive)\n        .reduce(0) { $0 + $1.spentUSD }\n}\nText(\"\\(total)\")",
            "let overBy = if state == .over {\n    job.spentUSD - job.budgetUSD\n} else {\n    0\n}\nText(\"\\(overBy)\")",
            "var overBy: Double {\n    if job.spentUSD > job.budgetUSD {\n        job.spentUSD - job.budgetUSD\n    } else {\n        0\n    }\n}\nText(\"\\(overBy)\")",
            "var overBy: Double {\n    switch state {\n    case .over: job.spentUSD - job.budgetUSD\n    default: 0\n    }\n}\nText(\"\\(overBy)\")",
            // Round 10: a returned closure over lines, a nested closure's own return, and a
            // name holding "return".
            "func activeTotal() -> Double {\n    return jobs.reduce(0) { sum, job in\n        sum + job.spentUSD\n    }\n}\nText(\"\\(activeTotal())\")",
            "var activeTotal: Double {\n    jobs.filter { job in\n        return job.isActive\n    }\n    .reduce(0) { $0 + $1.spentUSD }\n}\nText(\"\\(activeTotal)\")",
            "var net: Double { job.spentUSD - job.returnedCredit }\nText(\"\\(net)\")",
        ]
        for code in offenders {
            XCTAssertFalse(Self.amountsByHand(code).isEmpty, "passed the amount guard: \(code)")
        }
        // A formatter of the same name in another file is not the pane's formatter.
        let lookalike = #"private static func money(_ v: Double) -> String { String(format: "$%.4f", v) }"#
        XCTAssertFalse(Self.amountsByHand(lookalike, file: "AgentTools.swift").isEmpty)
        XCTAssertFalse(Self.amountsByHand("static func money(_ usd: Double) -> String {\n    \"$\" + String(usd)\n}\nstatic func money(_ usd: Float) -> String {\n    \"$\" + String(usd)\n}", file: "AgentsView.swift").isEmpty,
                       "only the one formatter is exempt, not an overload")
        for code in [#"let s = "\(AgentsView.spentOfBudget(j.spentUSD, j.budgetUSD))""#,
                     #"let s = "workers=\(job.workers.count) \(j.title)""#,
                     // An amount kept as a number is not text.
                     #"let budget = (input["budget_usd"] as? Double) ?? 5"#,
                     #"let over = job.spentUSD > job.budgetUSD"#,
                     #"Text(AgentsView.spentOfBudget(job.spentUSD, job.budgetUSD))"#,
                     // Round 5 P3: a literal key beside numeric `+` is not text.
                     #"job.spentUSD += (usage["cost_usd"] as? Double) ?? 0"#,
                     #"let b = (input["budget_usd"] as? Double).map { $0 + 1 } ?? 5"#,
                     // Round 6 P3: a comparison is a Bool, and a func whose parameter has an
                     // amount default returns no amount.
                     "let over = job.spentUSD > job.budgetUSD\nText(over ? \"Over\" : \"OK\")",
                     // Round 8 P3: a ternary between two literals is a string, not an amount.
                     "let label = job.spentUSD > job.budgetUSD ? \"Over budget\" : \"On budget\"\nText(label)",
                     "func startSwarm(title: String, budgetUSD: Double = 5.0) -> AgentJob {\n    let job = AgentJob(title: title, budgetUSD: budgetUSD)\n    return job\n}\nlet job = startSwarm(title: t)\nlet s = \"\\(job.title)\""] {
            XCTAssertEqual(Self.amountsByHand(code), [], code)
        }
        for code in [#"let s = "\(AgentsView.money(x)) spent""#, #"case .usage: return "$""#,
                     #"let p = "50% of the work""#, "// \"$%.2f\" in a comment"] {
            XCTAssertEqual(Self.amountsByHand(code), [], code)
        }
    }

    /// Wave 23 round 1: the join scan read only `) of \(AgentsView.money(` in AgentsView.
    func testTheJoinGuardCatchesEverySpelling() {
        let offenders = [
            #"Text("\(Self.money(job.spentUSD)) of \(Self.money(job.budgetUSD))")"#,
            #"Text("\(AgentsView.money(job.spentUSD)) / \(AgentsView.money(job.budgetUSD))")"#,
            #"lines.append("budget: \(AgentsView.money(j.spentUSD)) of \(AgentsView.money(j.budgetUSD))")"#,
            #"let s = "\(money(spent)) out of \(money(budget))""#,
            // Round 2: any words between, plain `+`, a join split over lines, another formatter.
            #"let s = "\(AgentsView.money(a)) of the \(AgentsView.money(b)) budget""#,
            #"let s = "\(AgentsView.money(a)), over the \(AgentsView.money(b)) budget""#,
            #"let s = "\(money(a)) spent of \(money(b))""#,
            #"let s = AgentsView.money(a) + " of " + AgentsView.money(b)"#,
            "let s = \"\\(AgentsView.money(a)) of \"\n    + \"\\(AgentsView.money(b))\"",
            #"let s = "\(money(a)) of \(DecisionUsageSummary.money(b) ?? "")""#,
            #"let s = "\( AgentsView.money(a) ) OF \( AgentsView.money(b) )""#,
            // Round 3: the formatter passed around as a value.
            #"let s = [a, b].map(AgentsView.money).joined(separator: " of ")"#,
            #"let m = AgentsView.money"#,
            // Round 4: a money value kept under any name, then joined.
            "let spend = AgentsView.money(job.spentUSD)\nlet s = \"\\(spend) of \\(AgentsView.money(job.budgetUSD))\"",
            "let total = AgentsView.money(a)\nlet limit = AgentsView.money(b)\nlet s = \"\\(total) of \\(limit)\"",
            // Round 5: a computed property, a modifier, a helper function, a getter over lines.
            "private var spentText: String { AgentsView.money(job.spentUSD) }\nvar body: some View { Text(\"\\(spentText) of \\(AgentsView.money(job.budgetUSD))\") }",
            "private let spend = AgentsView.money(a)\nlet s = \"\\(spend) of \\(AgentsView.money(b))\"",
            "func spentText() -> String { AgentsView.money(job.spentUSD) }\nlet s = \"\\(spentText()) of \\(AgentsView.money(b))\"",
            "private var spentText: String {\n    AgentsView.money(job.spentUSD)\n}\nlet s = \"\\(spentText) of \\(AgentsView.money(b))\"",
            // Round 6: held values joined without an interpolation.
            "let spend = AgentsView.money(a)\nlet limit = AgentsView.money(b)\nlet s = Text(spend) + Text(\" of \") + Text(limit)",
            "let spend = AgentsView.money(a)\nlet limit = AgentsView.money(b)\nlet s = String(format: \"%@ of %@\", spend, limit)",
            "let spend = AgentsView.money(a)\nlet limit = AgentsView.money(b)\nlet s = [spend, limit].joined(separator: \" of \")",
            "let spend = AgentsView.money(a)\nlet s = Text(spend) + Text(\" of \\(AgentsView.money(b))\")",
        ]
        for code in offenders {
            XCTAssertFalse(Self.joinsByHand(code).isEmpty, "passed the join guard: \(code)")
        }
        let own = """
            static func spentOfBudget(_ spent: Double, _ budget: Double) -> String {
                return "\\(money(spent)) of \\(money(budget))"
            }
            """
        XCTAssertEqual(Self.joinsByHand(own, file: "AgentsView.swift"), [], "the one join that is allowed")
        XCTAssertFalse(Self.joinsByHand(own, file: "AgentTools.swift").isEmpty, "a lookalike in another file")
        XCTAssertEqual(Self.joinsByHand(#"Text("\(AgentsView.spentOfBudget(a, b))")"#), [])
        XCTAssertEqual(Self.joinsByHand("let spend = AgentsView.money(job.spentUSD)\nText(spend)"), [],
                       "one money value, kept and shown, is not a join")
        XCTAssertEqual(Self.joinsByHand("let lines = jobs.map { AgentsView.money($0.spentUSD) }\nfunc f() {\n    var line = \"\\(AgentsView.money(w.spentUSD))\"\n    lines.append(line)\n}"), [],
                       "two held names in a statement that makes no text")
    }

    /// In the agent sources' words: a "$" (typed or as `\u{24}`; the event glyph
    /// `case .usage: return "$"` is the one allowed), an interpolated amount (a value named
    /// spent, budget, cost, usd or price) that is not `money(...)` or `spentOfBudget(...)`,
    /// a Foundation currency or number formatter, or `format:` beside a float spec. Read per
    /// statement by `SwiftSource`, outside AgentsView's two formatters only.
    static func amountsByHand(_ text: String, file: String = "AgentsView.swift") -> [String] {
        var out: [String] = []
        let floatSpec = #"%[-+0#]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:ll|l|L)?[fFeEgG]"#
        let formatted = #"^\s*(?:AgentsView\.|Self\.)?(?:money|spentOfBudget)\s*\("#
        let amountWords = ["spent", "spend", "budget", "cost", "usd", "price"]
        let statements = outsideTheFormatters(SwiftSource.statements(text), file: file)
        let amounts = amountNames(statements, amountWords: amountWords)
        func isAmount(_ name: String) -> Bool {
            amounts.contains(name) || amountWords.contains(where: name.lowercased().contains)
        }
        for st in statements {
            out += rawAmountsMadeText(st, isAmount: isAmount)
            let code = st.code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if code == #"case .usage: return """#, st.literals.map(\.text) == ["$"] { continue }
            for lit in st.literals {
                if lit.text.contains("$") || lit.text.range(of: #"\\u\{0*24\}"#, options: .regularExpression) != nil {
                    out.append("line \(lit.line): \"\(lit.text)\"")
                }
                for value in lit.interpolations where value.range(of: formatted, options: .regularExpression) == nil {
                    let names = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
                    if names.contains(where: isAmount) {
                        out.append("line \(lit.line): an amount interpolated by hand: \\(\(value))")
                    }
                }
            }
            // `.currency` or `.Currency` as a member, never inside a name (SessionConcurrency).
            if let r = code.range(of: #"(?i)\.currency\b|\bnumberformatter\b|\.number\b|\bspecifier\s*:"#, options: .regularExpression) {
                out.append("line \(st.line): \(code[r])")
            }
            if code.contains("format:"), st.literals.contains(where: { $0.text.range(of: floatSpec, options: .regularExpression) != nil }) {
                out.append("line \(st.line): format: with a float spec")
            }
        }
        return out
    }

    /// Round 4: an amount field read (a name holding spent, spend, budget, cost, usd or price,
    /// or a name the file fills from one) that is made text outside `money(` or
    /// `spentOfBudget(`: inside `String(`, `Text(` or `print(`, in a statement that calls
    /// `.formatted` or `.description` (round 5: after any expression, `(a - b).formatted()`), or
    /// beside a literal joined with `+`. An amount kept as a number is not text.
    private static func rawAmountsMadeText(_ st: SwiftSource.Statement, isAmount: (String) -> Bool) -> [String] {
        let code = Array(st.code)
        let allowed = spans(in: code, of: ["money(", "spentOfBudget("])
        let makesText = spans(in: code, of: ["String(", "Text(", "print("])
        let formats = st.code.contains(".formatted") || st.code.contains(".description")
        let joinsALiteral = st.code.range(of: #"""\s*\+|\+\s*"""#, options: .regularExpression) != nil
        var out: [String] = []
        for (range, name) in identifiers(code) where isAmount(name) {
            guard !allowed.contains(where: { $0.contains(range.lowerBound) }) else { continue }
            if joinsALiteral || formats || makesText.contains(where: { $0.contains(range.lowerBound) }) {
                out.append("line \(st.line): \(name) made text by hand")
            }
        }
        return out
    }

    /// The names the file fills from an amount (round 5: `let left = job.budgetUSD -
    /// job.spentUSD` makes `left` an amount; round 6: a computed property or a `func` whose
    /// single expression or `return` reads one), followed through chains. An amount passed into
    /// a call (`submit(budgetUSD: budget)`) does not make the result one, except through a
    /// number conversion or `max`, `min`, `abs`, `round`; a value that is a comparison is a
    /// Bool, not an amount.
    private static func amountNames(_ statements: [SwiftSource.Statement], amountWords: [String]) -> Set<String> {
        let values = declaredValues(statements)
        var names = Set<String>()
        var grew = true
        while grew {
            grew = false
            for (name, exprs) in values where !names.contains(name) {
                let readsAnAmount = exprs.contains { expr in
                    guard !isAComparison(expr) else { return false }
                    let code = Array(expr)
                    let calls = spans(in: code, ofAnyCallExcept: ["Double", "Decimal", "Float", "abs", "max", "min", "round"])
                    return identifiers(code).contains { r, n in
                        !calls.contains(where: { $0.contains(r.lowerBound) })
                            && (names.contains(n) || amountWords.contains(where: n.lowercased().contains))
                    }
                }
                if readsAnAmount { names.insert(name); grew = true }
            }
        }
        return names
    }

    /// A value that is no amount: itself a comparison, a Bool (a comparison outside every bracket, with
    /// no `?` choosing between amounts (round 7: `a > b ? a - b : 0` is an amount, and so is a
    /// sum past a filter's `{ $0.status != .done }`), or a ternary between two literals.
    private static func isAComparison(_ expr: String) -> Bool {
        var depth = 0, top = ""
        for ch in expr {
            if "([{".contains(ch) { depth += 1; continue }
            if ")]}".contains(ch) { depth = max(0, depth - 1); continue }
            if depth == 0 { top.append(ch) }
        }
        let trimmed = top.trimmingCharacters(in: .whitespaces)
        // An if or switch expression chooses a value, whatever it compares (round 8).
        if trimmed.hasPrefix("if ") || trimmed.hasPrefix("switch ") { return false }
        // A ternary between two literals is a string, not an amount (round 8).
        if trimmed.range(of: #"\?\s*""\s*:\s*""$"#, options: .regularExpression) != nil { return true }
        return !top.contains("?") && top.range(of: #"(?<!-)>|<|==|!="#, options: .regularExpression) != nil
    }

    /// Each declaration's value: what follows a `let` or `var`'s `=`, or a computed property's
    /// or `func`'s single expression or `return` expressions, its body read over lines.
    private static let returnWord = try! NSRegularExpression(pattern: #"\breturn\b"#)

    private static func declaredValues(_ statements: [SwiftSource.Statement]) -> [(String, [String])] {
        func braces(_ c: String) -> Int { c.filter { $0 == "{" }.count - c.filter { $0 == "}" }.count }
        var out: [(String, [String])] = []
        for (k, st) in statements.enumerated() {
            guard let name = declaredName(st.code) else { continue }
            let isFunc = st.code.range(of: #"\bfunc\s"#, options: .regularExpression) != nil
            let brace = st.code.firstIndex(of: "{"), eq = st.code.firstIndex(of: "=")
            if !isFunc, let eq, brace.map({ eq < $0 }) ?? true {
                // A value over lines (`let x = if c {` ... `}`) is read to its closing brace.
                var value = String(st.code[st.code.index(after: eq)...])
                var depth = braces(st.code), j = k + 1
                while depth > 0, j < statements.count {
                    value += "\n" + statements[j].code
                    depth += braces(statements[j].code)
                    j += 1
                }
                out.append((name, [value]))
                continue
            }
            guard let brace else { continue }
            var body = [String(st.code[st.code.index(after: brace)...])]
            var depth = braces(st.code), j = k + 1
            while depth > 0, j < statements.count {
                body.append(statements[j].code)
                depth += braces(statements[j].code)
                j += 1
            }
            let parts = body.map { part -> String in
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.hasSuffix("}") ? String(t.dropLast()).trimmingCharacters(in: .whitespaces) : t
            }.filter { !$0.isEmpty }
            // The whole body is a value, read with every line of every closure in it (round 10:
            // a returned `reduce` whose closure runs over lines, a nested closure's own
            // `return`), and so is each `return` on its own (`guard ... else { return 0 }`
            // must not make the body read as a comparison): an implicit single expression, an
            // `if` or `switch` over lines, and every return wherever it sits.
            let returns: [String] = parts.flatMap { part -> [String] in
                let ns = part as NSString
                return returnWord.matches(in: part, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(from: $0.range.location + $0.range.length) }
            }
            out.append((name, returns + [parts.joined(separator: "\n")]))
        }
        return out
    }

    /// The name a declaration statement declares, whatever its attributes and modifiers:
    /// `let x`, `private var x`, `static func x(`.
    private static func declaredName(_ code: String) -> String? {
        let rx = try! NSRegularExpression(pattern: #"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|public|internal|open|static|class|lazy|weak|final|override|nonisolated|mutating)(?:\(set\))?\s+)*(?:let|var|func)\s+([A-Za-z_]\w*)"#)
        let ns = code as NSString
        guard let m = rx.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Each identifier (letters, digits, `_`) with where it sits.
    private static func identifiers(_ code: [Character]) -> [(Range<Int>, String)] {
        var out: [(Range<Int>, String)] = [], k = 0
        while k < code.count {
            guard code[k].isLetter || code[k] == "_" else { k += 1; continue }
            let start = k
            while k < code.count, code[k].isLetter || code[k].isNumber || code[k] == "_" { k += 1 }
            out.append((start..<k, String(code[start..<k])))
        }
        return out
    }

    /// Where each call's argument list sits (an identifier right before "("), the named
    /// number conversions aside.
    private static func spans(in code: [Character], ofAnyCallExcept transparent: Set<String>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (range, name) in identifiers(code) where range.upperBound < code.count && code[range.upperBound] == "(" {
            guard !transparent.contains(name) else { continue }
            var k = range.upperBound + 1, depth = 1
            while k < code.count, depth > 0 {
                if code[k] == "(" { depth += 1 }
                if code[k] == ")" { depth -= 1 }
                k += 1
            }
            out.append(range.upperBound..<k)
        }
        return out
    }

    /// Where each call to one of `names` (each ending in "(") sits, to its own closing
    /// parenthesis. A name starting with "." is a member call and needs no word boundary.
    private static func spans(in code: [Character], of names: [String]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for name in names.map(Array.init) {
            var p = 0
            while p + name.count <= code.count {
                let boundary = name.first == "." || p == 0 || !(code[p - 1].isLetter || code[p - 1].isNumber || code[p - 1] == "_")
                guard boundary, Array(code[p..<p + name.count]) == name else { p += 1; continue }
                var k = p + name.count, depth = 1
                while k < code.count, depth > 0 {
                    if code[k] == "(" { depth += 1 }
                    if code[k] == ")" { depth -= 1 }
                    k += 1
                }
                out.append(p..<k)
                p += name.count
            }
        }
        return out
    }

    /// Two money values in one statement, outside AgentsView's two formatters: `money(` calls,
    /// whoever's, and names the file holds a money value in (round 5: any `let`, `var` or
    /// `func`, with any modifier, whose declaration, or body over lines, calls `money(` or
    /// `spentOfBudget(`) in a statement that makes text; or the formatter passed around as a value
    /// (`.map(AgentsView.money)`, `let m = AgentsView.money`).
    static func joinsByHand(_ text: String, file: String = "AgentsView.swift") -> [String] {
        let statements = outsideTheFormatters(SwiftSource.statements(text), file: file)
        let moneyCall = #"\b(?:money|spentOfBudget)\s*\("#
        func braces(_ c: String) -> Int { c.filter { $0 == "{" }.count - c.filter { $0 == "}" }.count }
        var held = Set<String>()
        for (k, st) in statements.enumerated() {
            guard let name = declaredName(st.code) else { continue }
            var block = st.code, depth = braces(st.code), j = k + 1
            while depth > 0, j < statements.count {
                block += "\n" + statements[j].code
                depth += braces(statements[j].code)
                j += 1
            }
            if block.range(of: moneyCall, options: .regularExpression) != nil { held.insert(name) }
        }
        return statements.compactMap { st in
            let calls = st.code.components(separatedBy: "money").dropFirst()
                .filter { $0.drop(while: \.isWhitespace).hasPrefix("(") }.count
            // Held values count anywhere in a statement that makes text (a literal, `Text(`,
            // `String(`, `.joined`), the declaring name aside. Names are file-wide, so a
            // statement making no text (`lines.append(line)`) counts none.
            let makesText = !st.literals.isEmpty || ["Text(", "String(", ".joined"].contains(where: st.code.contains)
            let own = declaredName(st.code).map { held.contains($0) ? 1 : 0 } ?? 0
            let names = makesText ? identifiers(Array(st.code)).map(\.1).filter(held.contains).count - own : 0
            let asValue = st.code.range(of: #"\bmoney\b(?!\s*\()"#, options: .regularExpression) != nil
            return calls + names >= 2 || asValue ? "line \(st.line): \(st.code.trimmingCharacters(in: .whitespacesAndNewlines))" : nil
        }
    }

    /// Every statement but the bodies of AgentsView's `money(_ usd: Double)` and
    /// `spentOfBudget(_:_:)`, the two formatters every amount goes through (the first holds
    /// the "$0.00" fallback, the second the one join). A function of the same name in another
    /// file, or an overload, is read like any other code.
    private static func outsideTheFormatters(_ statements: [SwiftSource.Statement], file: String) -> [SwiftSource.Statement] {
        var pending = file == "AgentsView.swift"
            ? ["static func money(_ usd: Double) -> String", "static func spentOfBudget(_ spent: Double, _ budget: Double) -> String"]
            : []
        var out: [SwiftSource.Statement] = [], depth = 0, inside = false
        for st in statements {
            if !inside, let k = pending.firstIndex(where: st.code.contains) {
                pending.remove(at: k)
                inside = true; depth = 0
            }
            if inside {
                depth += st.code.filter { $0 == "{" }.count - st.code.filter { $0 == "}" }.count
                if depth <= 0, st.code.contains("}") { inside = false }
                continue
            }
            out.append(st)
        }
        return out
    }
}
