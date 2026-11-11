import Foundation

/// "Make a to-do list for the weekend" (D180 item 1), answered by Grux. It
/// added one task titled "List for the weekend" through the task card; with
/// that shape gone, grux-local:2b tried add_task with the whole ask as the
/// task and answered "You'll need to use one of the available functions like
/// `add_task`" (live 8:19 AM Nov 6). An ask to start a list with nothing on it
/// has nothing to add yet, so Grux asks what goes on it, in the shape the task
/// card adds at once. A list with its items ("Make a to-do list: milk, eggs")
/// goes to the model, which is offered the task tools (`LocalTurn.rank`).
enum ToDoListAsk {
    /// The whole message: start a to-do or task list, for at most four words
    /// of when or what ("for the weekend", "for my trip"), nothing on it and
    /// nowhere else ("in Notion", "on Trello": not Grux's task list, W59-FIX P3).
    private static let ask = try! NSRegularExpression(pattern:
        #"^(?:(?:hey\s+)?grux[,:]?\s+)?(?:please\s+)?(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?"#
        + #"(?:make|create|start|begin|set\s+up)\s+(?:me\s+)?(?:a\s+|my\s+)?(?:new\s+)?(?:to-?do|to\s+do|task)\s+list"#
        + #"(?:\s+for\s+(?!.*\b(?:with|and|including|plus|of|in|on|at|into|via|using)\b)[a-z']+(?:\s+[a-z']+){0,3})?"#
        + #"\s*[.!?]?\s*$"#, options: [.caseInsensitive])

    static func matches(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
        guard ask.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil else { return false }
        // A name after "for" is somewhere else ("for Notion", "for Apple
        // Reminders"), unless it is a day or a month (W59-FIX round 2 P3), a
        // place a trip goes to ("my trip to Paris", "moving to New York"), or a
        // person's own day ("Mom's birthday"); a workspace is an app's
        // (W59-P3). Closed lists only: "syncing to Notion" and "Notion's inbox"
        // name an app (W60-FIX P2).
        guard let r = t.range(of: " for ", options: .caseInsensitive) else { return true }
        let words = t[r.upperBound...].split(separator: " ").map {
            String($0).trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
        let cased = t[r.upperBound...].split(separator: " ").map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }
        var place = false
        for (i, word) in words.enumerated() {
            if appPlaces.contains(word) { return false }
            guard let c = cased[i].first, c.isUppercase else { place = false; continue }
            place = place || (i > 1 && words[i - 1] == "to" && tripWords.contains(words[i - 2]))
            if place || calendarNames.contains(word) { continue }
            if word.hasSuffix("'s"), i + 1 < words.count, dayWords.contains(words[i + 1]) { continue }
            return false
        }
        return true
    }
    /// Words only an app's list sits in. Not "board" or "sheet": "the board
    /// meeting" is a day's list (W60-FIX round 2 P3); "Jira's board" refuses
    /// as a possessive before a word that is not a day.
    private static let appPlaces: Set<String> = ["workspace", "database", "channel"]
    /// "trip to Paris", "moving to Denver": what goes before a place.
    private static let tripWords: Set<String> = [
        "trip", "trips", "move", "moving", "flight", "visit", "travel", "traveling", "travelling", "drive",
        "vacation", "holiday", "honeymoon",
    ]
    /// "Mom's birthday": a person's own day.
    private static let dayWords: Set<String> = [
        "birthday", "wedding", "party", "shower", "graduation", "anniversary", "visit", "retirement",
        "funeral", "recital", "move", "trip",
    ]
    private static let calendarNames: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "christmas", "thanksgiving", "easter", "halloween", "i", "eve", "new", "year's",
    ]

    /// The example is one the task card takes with no model and no judge
    /// (`PIMIntents` "add X to my tasks", D151).
    static let reply = "What should go on it? Tell me one thing at a time, like \u{201C}add buy groceries to my tasks\u{201D}, "
        + "and I'll add each one to your task list."
}
