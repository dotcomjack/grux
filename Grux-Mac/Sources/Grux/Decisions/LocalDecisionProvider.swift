import Foundation

/// The on-device provider. Exact spoken phrases and whole-word overlap, no
/// network, no key. It is what everyone gets before they add a key, so its
/// confidence is honest: an exact phrase clears the execute threshold, a few
/// shared words do not, and a yes/no question it cannot judge answers 0.5.
struct LocalDecisionProvider: DecisionProvider {
    let kind: DecisionProviderKind = .local

    static let notACommand = "not_a_command"

    /// How the voice gate introduces what was said. One constant, because the
    /// scorer below has to know which part of the state is the utterance and
    /// which part is context Grux added.
    static let heardPrefix = "Heard: "

    /// How much of what was said a phrase must cover before an exact hit reads
    /// as a command.
    ///
    /// WITHOUT THIS, A PHRASE ANYWHERE IN A SENTENCE FIRED. Measured on the
    /// on-device path, which is what every keyless install runs: "we should
    /// mute the group chat" MUTED THE MICROPHONE, a television advert reading
    /// "mute the ads with our premium subscription" muted it too, and "I told
    /// you Grux can open my calendar for me" opened the calendar. All three
    /// scored 0.95, over any execute bar, because `contains` is true for a
    /// four-letter phrase in a nine-word sentence.
    ///
    /// Half is the line between "they said the command" and "the command
    /// appeared in what they said". It costs the long polite phrasings ("could
    /// you please open my calendar for me", 0.40) on the keyless path, where
    /// the honest answer to a half-recognised sentence is to do nothing; with
    /// a Decisions key that same sentence is judged on meaning instead.
    static let phraseCoverage = 0.5

    /// Text as it would be SPOKEN: lowercased, every character that is not a
    /// letter or a digit read as a space, runs of spaces collapsed. Line breaks
    /// stay, so context lines never join into one phrase.
    ///
    /// Measured 2026-09-27: Whisper wrote "open Self-Upgrade" as "Open self
    /// upgrade." and the raw substring test could never find "self-upgrade" in
    /// it. Nobody pronounces a hyphen, so neither side of the match may keep one.
    static func spoken(_ text: String) -> String {
        text.lowercased()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                String(line.map { $0.isLetter || $0.isNumber ? $0 : " " })
                    .split(separator: " ").joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private static func spokenPhrases(_ description: String) -> [String] {
        description.split(separator: "|").map { spoken(String($0)) }.filter { !$0.isEmpty }
    }

    /// The WHOLE utterance is the phrase, give or take where the spaces fell:
    /// Whisper writes "Jax HQ" as "JaxHQ" and "Focus log" as "Focuslog". Only
    /// the whole utterance, never a piece of a longer one, so running words
    /// together cannot make a command out of a sentence ("reopen chattering").
    private static func sameIgnoringSpaces(_ phrase: String, _ said: String) -> Bool {
        !said.isEmpty && phrase.replacingOccurrences(of: " ", with: "") == said.replacingOccurrences(of: " ", with: "")
    }

    /// What was SAID, without the context Grux wrapped around it.
    static func heard(in state: String) -> String {
        for line in state.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix(heardPrefix) {
            return String(line.dropFirst(heardPrefix.count))
        }
        return state
    }

    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
        let started = Date()
        var out: [String: DecisionAnswer] = [:]
        for (name, q) in questions {
            switch q {
            case .choice(_, let criteria): out[name] = Self.matchChoice(state: state, criteria: criteria)
            case .noul: out[name] = .noul(0.5)
            case .score: out[name] = .score(0, confidence: 0)
            }
        }
        return DecisionResult(answers: out,
                              latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                              inputTokens: 0, outputTokens: 0, provider: .local)
    }

    /// Whether an option could score above zero here: one of its phrases is in
    /// the state, or one of its words (three letters or more) is a whole word
    /// in it. This is exactly the test `matchChoice` scores with, shared so a
    /// caller that drops options this says no to can prove it changed no
    /// on-device answer: an option it rejects scores 0 and can never win.
    static func couldMatch(state: String, description: String) -> Bool {
        let lowered = spoken(state)
        let phrases = spokenPhrases(description)
        let said = spoken(heard(in: state))
        if phrases.contains(where: { lowered.contains($0) || sameIgnoringSpaces($0, said) }) { return true }
        let words = Set(phrases.joined(separator: " ").split { !$0.isLetter }.map(String.init).filter { $0.count > 2 })
        return words.contains { ChatIntentClassifier.containsAnyWord(lowered, keywords: [$0]) }
    }

    static func matchChoice(state: String, criteria: [String: String]) -> DecisionAnswer {
        let lowered = spoken(state)
        // Coverage is measured against what was SAID. Against the whole state
        // it would shrink every time Grux added a line of context, so the same
        // words would mean different things depending on how recently Grux
        // had spoken.
        let said = spoken(heard(in: state))
        var scores: [String: Double] = [:]
        // Among exact phrase hits the longest phrase wins: "open my calendar"
        // beats "open", and a tie between options is not left to dictionary
        // order.
        var hitLength: [String: Int] = [:]
        for (option, description) in criteria where option != notACommand {
            let phrases = spokenPhrases(description)
            if let longest = phrases.filter({ lowered.contains($0) || sameIgnoringSpaces($0, said) }).map(\.count).max() {
                let covers = said.isEmpty ? 1.0 : Double(longest) / Double(said.count)
                if covers >= phraseCoverage {
                    scores[option] = 0.95
                    hitLength[option] = longest
                    continue
                }
                // The phrase is in there, buried. Scored as a weak signal that
                // cannot reach any execute bar: with a key the model judges
                // the sentence, and without one Grux keeps still.
                scores[option] = 0.4
                hitLength[option] = longest
                continue
            }
            let words = Set(phrases.joined(separator: " ").split { !$0.isLetter }.map(String.init).filter { $0.count > 2 })
            guard !words.isEmpty else { scores[option] = 0; continue }
            let hits = words.filter { ChatIntentClassifier.containsAnyWord(lowered, keywords: [$0]) }.count
            scores[option] = 0.6 * Double(hits) / Double(words.count)
        }
        let best = scores.max { a, b in
            if a.value != b.value { return a.value < b.value }
            return (hitLength[a.key] ?? 0) < (hitLength[b.key] ?? 0)
        }
        let bestScore = best?.value ?? 0
        if let best, bestScore >= 0.5 {
            var probs = scores
            probs[notACommand] = max(0, 1 - bestScore)
            return .choice(best.key, confidence: bestScore, probabilities: probs)
        }
        var probs = scores
        probs[notACommand] = 1 - bestScore
        return .choice(notACommand, confidence: 1 - bestScore, probabilities: probs)
    }
}
