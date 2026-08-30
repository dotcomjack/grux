import Foundation

// Canonical redactor for anything untrusted entering a Claude prompt - OCR text, ambient
// transcripts, file contents we're surfacing to the model, etc. Replaces secret-shaped
// tokens in-place with `[REDACTED:KIND]`. Patterns run most-specific-first so a Stripe
// live key becomes `[REDACTED:STRIPE_LIVE_SECRET]`, not the generic high-entropy tag.
enum SecretRedactor {

    // Ordered: most-specific prefixes first, JWT before generic entropy, generic last.
    private static let patterns: [(tag: String, regex: NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("ANTHROPIC_KEY", #"sk-ant-[A-Za-z0-9_\-]{10,}"#),
            // Generic OpenAI-style secret key (sk-... and sk-proj-...). Runs after
            // the more specific sk-ant- so Anthropic keys keep their own tag. The
            // 16-char floor catches real keys (which are far longer) while leaving
            // short "sk-" prose alone.
            ("OPENAI_KEY", #"sk-(?:proj-)?[A-Za-z0-9_\-]{16,}"#),
            ("AWS_KEY", #"AKIA[0-9A-Z]{16}"#),
            ("PEM", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            ("GITHUB_PAT", #"ghp_[A-Za-z0-9]{30,}"#),
            ("GITHUB_FINE_GRAINED", #"github_pat_[A-Za-z0-9_]{20,}"#),
            ("SLACK_TOKEN", #"xox[baprs]-[A-Za-z0-9\-]{20,}"#),
            ("STRIPE_LIVE_SECRET", #"sk_live_[A-Za-z0-9]{20,}"#),
            ("STRIPE_LIVE_PUBLIC", #"pk_live_[A-Za-z0-9]{20,}"#),
            ("STRIPE_LIVE_RESTRICTED", #"rk_live_[A-Za-z0-9]{20,}"#),
            ("ELEVENLABS_KEY", #"sk_[a-f0-9]{48,}"#),
            ("JWT", #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
        ]
        return raw.compactMap { pair in
            (try? NSRegularExpression(pattern: pair.1, options: [])).map { (pair.0, $0) }
        }
    }()

    // Generic high-entropy run - run LAST so specific patterns get first crack.
    // Uses word-ish lookarounds and a 40-char minimum; we only redact if the token
    // spans ≥4 character classes (upper, lower, digit, symbol), which filters
    // out long base-ten numbers, repeated letters, ordinary words, etc.
    private static let entropyRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])[A-Za-z0-9+/=_\-]{40,}(?![A-Za-z0-9])"#,
            options: []
        )
    }()

    static func redact(_ input: String) -> String {
        var out = input
        for (tag, regex) in patterns {
            out = replaceAll(in: out, regex: regex, with: "[REDACTED:\(tag)]")
        }
        out = replaceHighEntropy(in: out)
        return out
    }

    // Idempotent-friendly wrapper - marks untrusted DATA clearly so Claude can tell
    // it apart from the user's own instructions. Callers should pipe ANY screen/ambient/file
    // text through this before injecting into a prompt.
    static func wrapAsUntrusted(_ kind: String, _ body: String) -> String {
        return "<untrusted_data kind=\"\(kind)\">\n\(redact(body))\n</untrusted_data>"
    }

    // MARK: - Internals

    private static func replaceAll(in input: String, regex: NSRegularExpression, with replacement: String) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static func replaceHighEntropy(in input: String) -> String {
        guard let regex = entropyRegex else { return input }
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let matches = regex.matches(in: input, options: [], range: range)
        guard !matches.isEmpty else { return input }

        // Walk matches in reverse so earlier ranges stay valid.
        var result = input
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let token = String(result[swiftRange])
            // Skip anything that's already a redaction marker - keeps redact() idempotent.
            if token.hasPrefix("[REDACTED:") { continue }
            if charClassCount(token) >= 4 {
                result.replaceSubrange(swiftRange, with: "[REDACTED:HIGH_ENTROPY]")
            }
        }
        return result
    }

    private static func charClassCount(_ s: String) -> Int {
        var upper = false, lower = false, digit = false, symbol = false
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A { upper = true }
            else if scalar.value >= 0x61 && scalar.value <= 0x7A { lower = true }
            else if scalar.value >= 0x30 && scalar.value <= 0x39 { digit = true }
            else { symbol = true }
        }
        var n = 0
        if upper { n += 1 }
        if lower { n += 1 }
        if digit { n += 1 }
        if symbol { n += 1 }
        return n
    }

    #if DEBUG
    static func runSelfTest() {
        func assertContains(_ haystack: String, _ needle: String, _ label: String) {
            if !haystack.contains(needle) {
                NSLog("SecretRedactor selftest FAIL [\(label)]: expected to contain '\(needle)', got '\(haystack)'")
            }
        }
        // Anthropic key
        let r1 = redact("key is sk-ant-api03-ABCDEF0123456789abcdef more text")
        assertContains(r1, "[REDACTED:ANTHROPIC_KEY]", "anthropic")
        // AWS key
        let r2 = redact("aws: AKIAIOSFODNN7EXAMPLE end")
        assertContains(r2, "[REDACTED:AWS_KEY]", "aws")
        // PEM header
        let r3 = redact("-----BEGIN RSA PRIVATE KEY-----\nMIIEvQ...")
        assertContains(r3, "[REDACTED:PEM]", "pem")
        // Idempotency
        let r4 = redact(redact("key is sk-ant-api03-ABCDEF0123456789abcdef"))
        let r5 = redact("key is sk-ant-api03-ABCDEF0123456789abcdef")
        if r4 != redact(r5) {
            NSLog("SecretRedactor selftest FAIL [idempotency]: \(r4) != \(redact(r5))")
        }
    }
    #endif
}
