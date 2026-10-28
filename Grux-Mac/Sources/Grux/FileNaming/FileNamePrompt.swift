import Foundation
import GruxGuardrails

/// The naming call: the instruction, the text wrapped for the model, and the
/// boundary every reply crosses before it can become a file name.
///
/// Model output is untrusted (SECURITY.md section 2). A reply reaches the disk
/// only through `clean`, which returns nil, meaning "leave the file alone",
/// for anything it cannot make safe.
enum FileNamePrompt {

    /// Measured 2026-10-27 with `think: false` on the base qwen3.5:4b, once
    /// loaded: "Stripe Invoice Oct 2026", "Swift Build Error Log", "Delta
    /// Boarding Pass Nov 14", 0.6 to 0.9 s each. This is that probe prompt.
    /// Tuned 2026-10-28 on the eval's 150-item tuning set (grux-local:4b went
    /// from 112 to 126 of 135 useful names with the reader's largest-text line);
    /// the score that counts is the held-out set's, run once after tuning.
    /// The examples are general, not taken from the tuning items.
    static let system = """
    You name files from the text read off a screenshot or document. Reply with one file name of 2 to 6 words and nothing else.
    A screenshot also shows menus, sidebars, tabs and lists around the main content. Ignore them and name the main content: the open email, the open conversation, the selected settings page, the article's headline, the product on the page, the error.
    Make the name say what it is about and what kind of thing it is, the way a person would file it:
    - a receipt, bill, statement or ticket: the business that issued it and the kind, for example "Amtrak Train Ticket" or "Corner Bakery Receipt"
    - an email or chat: its subject, for example "School Picture Day Email"
    - an article: its topic, for example "Electric Bus Rollout Article"
    - a settings page: the setting, for example "Trackpad Settings"
    - an error or terminal output: the tool and the error, for example "Rust Borrow Checker Error"
    - a product page: the product, for example "Cast Iron Skillet"
    Use Title Case and only words from the text or plain words that describe it. No date stamps, no file extension, no quotes. Never include an account number, card number, password or code.
    """

    static func user(text: String) -> String {
        "Text from the file:\n<<<\n\(text)\n>>>\nFile name:"
    }

    /// The most a name may hold, in characters and in words.
    static let maxCharacters = 60
    static let maxWords = 8

    /// The model's reply made into a base name, or nil to leave the file alone.
    /// Pure: same reply, source text and extension, same answer.
    /// `fileExtension` is the file's own, stripped from the reply like any
    /// known one.
    static func clean(_ reply: String, sourceText: String, fileExtension: String? = nil) -> String? {
        // 1. First non-empty line, wrapping quotes and markdown off, then every
        //    trailing period and extension.
        guard var name = reply.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let wrapping = CharacterSet(charactersIn: "\"'`*#\u{201C}\u{201D}\u{2018}\u{2019}").union(.whitespaces)
        name = name.trimmingCharacters(in: wrapping)
        if let label = name.range(of: "file name:", options: [.caseInsensitive, .anchored]) {
            name = String(name[label.upperBound...]).trimmingCharacters(in: wrapping)
        }
        name = stripExtensions(name, own: fileExtension).trimmingCharacters(in: wrapping)
        name = stripExtensions(name, own: fileExtension)

        // 2. Nothing that can leave the folder or hide the file.
        name = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return Character(scalar)
        })
        while name.hasPrefix(".") || name.hasPrefix(" ") { name.removeFirst() }
        var words = name.split(whereSeparator: \.isWhitespace).map(String.init)

        // 3. 2 to 8 words, at most 60 characters, cut at a word boundary.
        if words.count > maxWords { words = Array(words.prefix(maxWords)) }
        while words.count > 1 && words.joined(separator: " ").count > maxCharacters { words.removeLast() }
        name = words.joined(separator: " ")
        guard words.count >= 2, name.count <= maxCharacters else { return nil }

        // 4. Hallucination guard: one word of 3 or more letters has to be a
        //    whole word of the text the model was given. Whole words, not
        //    substrings: "Ice" is inside "Invoice" and "The" is inside almost
        //    any text, so a substring match grounded an invented name
        //    (review 2026-10-28).
        let sourceWords = Set(letterWords(sourceText))
        let grounded = letterWords(name).contains { $0.count >= 3 && sourceWords.contains($0) }
        guard grounded else { return nil }

        // 5. Secret guard: no 6 or more digits in a row, counting a single
        //    space or hyphen between them as part of the run, so a card number
        //    written "4111 1111 1111 1111" or "4111-1111-1111-1111" is caught
        //    (review 2026-10-28). Also nothing the redactor would take, and no
        //    redaction marker the text already carried.
        // Six digits in a row, or eight split by single spaces or hyphens: a
        // card, account or reference number. A day and a year ("Oct 14 2026",
        // six digits across a space) is a date and stays.
        if name.range(of: #"[0-9]{6,}"#, options: .regularExpression) != nil { return nil }
        if name.range(of: #"[0-9](?:[ \-]?[0-9]){7,}"#, options: .regularExpression) != nil { return nil }
        if name.range(of: "REDACTED", options: .caseInsensitive) != nil { return nil }
        if SecretRedactor.redact(name, passes: .evidenceOnly) != name { return nil }

        // 6. Enough letters to be a name.
        guard name.filter(\.isLetter).count >= 2 else { return nil }
        return name
    }

    /// Extensions a reply may end in. A reply is untrusted and its source is
    /// text anybody can put in a download, so `Acme Invoice.pdf.txt` must not
    /// leave `.pdf` in the name, where Finder, hiding the real extension,
    /// shows the file as a PDF (review 2026-10-28).
    static let knownExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "svg",
        "txt", "rtf", "md", "csv", "json", "xml", "html", "htm", "doc", "docx", "xls", "xlsx",
        "ppt", "pptx", "key", "pages", "numbers", "zip", "dmg", "pkg", "app", "exe", "mov", "mp4",
        "m4a", "mp3", "wav", "eml", "ics", "vcf",
    ]

    /// `Invoice.pdf.txt.` becomes `Invoice`: trailing periods go, then every
    /// trailing `.ext` of 1 to 5 letters or digits that is a known extension
    /// or the file's own, repeated until neither is left. An unknown tail
    /// stays, so `Release v2.1` keeps its number.
    static func stripExtensions(_ input: String, own: String?) -> String {
        let ownExt = own?.lowercased()
        let trailing = CharacterSet(charactersIn: ".").union(.whitespaces)
        var name = input.trimmingCharacters(in: trailing)
        while let dot = name.lastIndex(of: ".") {
            let tail = name[name.index(after: dot)...]
            let lower = tail.lowercased()
            guard (1...5).contains(tail.count), tail.allSatisfy({ $0.isLetter || $0.isNumber }),
                  knownExtensions.contains(lower) || lower == ownExt else { break }
            name = String(name[..<dot]).trimmingCharacters(in: trailing)
        }
        return name
    }

    /// The words of `text`, split at anything that is not a letter, folded
    /// for case and diacritics.
    static func letterWords(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map {
            String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
    }
}
