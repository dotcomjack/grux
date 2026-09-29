import Foundation

/// Five identical red bubbles say nothing the first one did not, and they push
/// the conversation off the screen.
///
/// A run of the same notice is one row with a count. Consecutive is
/// load-bearing: grouping across a real message would reorder the transcript
/// and show an error above the turn that caused it, which is worse than the
/// repetition.
enum ErrorBubbleGrouping {
    enum Row: Identifiable, Equatable {
        case message(ChatMessage)
        case repeatedNotice(ChatMessage, count: Int)

        var id: UUID {
            switch self {
            case .message(let m): return m.id
            case .repeatedNotice(let m, _): return m.id
            }
        }

        static func == (a: Row, b: Row) -> Bool { a.id == b.id && a.count == b.count }

        var count: Int {
            if case .repeatedNotice(_, let n) = self { return n }
            return 1
        }
    }

    static func group(_ messages: [ChatMessage]) -> [Row] {
        var out: [Row] = []
        var index = 0
        while index < messages.count {
            let m = messages[index]
            guard m.isNotice else {
                out.append(.message(m)); index += 1; continue
            }
            var run = 1
            while index + run < messages.count,
                  messages[index + run].isNotice,
                  messages[index + run].content == m.content { run += 1 }
            out.append(.repeatedNotice(m, count: run))
            index += run
        }
        return out
    }

    /// What the card says about how often this happened. Empty for a single
    /// occurrence, because "1 time" is noise.
    static func repeatLabel(count: Int) -> String {
        count <= 1 ? "" : "\(count) times"
    }
}
