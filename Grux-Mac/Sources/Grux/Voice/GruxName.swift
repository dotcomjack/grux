import Foundation

/// What counts as someone saying "Grux". One place, used by every matcher.
///
/// THE OLD MATCHERS TOOK ANY WORD THAT STARTS "gr" PLUS A VOWEL. Measured on
/// the running app on 2026-09-21, during a meeting in the room: "great",
/// "grab", "green", "grand", "grain" and "growth" each counted as the person
/// saying Grux's name, and a chunk addressed by name goes to Chat whatever the
/// decision engine thinks of it. 17 of the day's 51 forced sends to Chat came
/// from that alone ("great" 5, "grab" 5), and Grux answered a meeting it was
/// not part of.
///
/// Two lists, because a greeting is evidence and a bare word is not:
/// - `loose`: every mishearing a recognizer has actually produced for the
///   name, including real words like "grew" and "grubs". Trusted only after a
///   greeting ("hey grubs" is someone calling Grux; "the grubs" is not).
/// - `strong`: spellings that are not English words. Trusted as a bare name,
///   and only at the START of a chunk, because "I told grux yesterday" is
///   someone talking ABOUT Grux, not to it.
enum GruxName {
    /// Apple's on-device recognizer (see WakeWordListener) and Whisper
    /// (WhisperVocab: "Grox", "Grooks") mishearings, as regex alternatives.
    static let loose = "(?:grux|grooks|groks|gruff|groose|grubs|grugs|groot|grocks|grucks|gruks|gruhks|gruz|groo|grew|grox|groux)"
    static let strong = "(?:grux|grooks|groks|grocks|grucks|gruks|gruhks|gruz|grox|groux)"
    static let greeting = "(?:hey|ok|okay|yo|hi|hay|aye|hi there|um|uh)"
}
