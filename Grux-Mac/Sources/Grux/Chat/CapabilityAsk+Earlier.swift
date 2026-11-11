import Foundation

extension CapabilityAsk {
    /// The person's earlier messages that went to the model. A message Grux
    /// answered itself carries `answeredWithoutModel` (set by ChatService on
    /// every exit before the model path), and leaves a chat as fresh as it
    /// was, so "What can you do for me?" after "What's on my calendar
    /// tomorrow?" still gets the list (wave 67 rounds 3 to 5).
    static func modelAsks(_ chat: [ChatMessage]) -> [String] {
        // An image turn reads as "", never an opening, as in `earlierTurns`.
        chat.filter { $0.role == .user && !$0.isNotice && !$0.answeredWithoutModel }
            .map { $0.imageData == nil ? $0.content : "" }
    }


    /// The person's messages before the newest one, for the asks that name
    /// "this" (`PrivacyAsk`, `SelfAsk`). A message that carried an image
    /// reads as "", which is never an opening: "What model is this?" after a
    /// photo sent with no words, or with only "Hi", asks about the photo
    /// (wave 71 round 2 P2).
    static func earlierTurns(_ chat: [ChatMessage]) -> [String] {
        chat.dropLast().filter { $0.role == .user && !$0.isNotice }.map { $0.imageData == nil ? $0.content : "" }
    }
}
