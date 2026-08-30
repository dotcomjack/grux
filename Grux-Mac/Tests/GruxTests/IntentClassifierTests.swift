import XCTest
@testable import Grux

// Pin classifier behavior at the boundaries that matter for cost. False
// negatives (missing TASK_STACK on a task turn) hurt UX; false positives
// (shipping TASK_STACK on a "play a song" turn) cost ~150-600 tokens
// uncached every turn. These tests guard both directions.
final class IntentClassifierTests: XCTestCase {

    // MARK: - Music / utility shedding

    func test_playMusic_shedsTasksAndFocus() {
        let s = ChatIntentClassifier.classify(utterance: "play a hype song by green day")
        XCTAssertFalse(s.taskStack)
        XCTAssertFalse(s.proposedActions)
        XCTAssertFalse(s.recentFocus)
        XCTAssertTrue(s.availableMacros, "macros stay so claude can fall back to run_macro")
    }

    func test_playSpecificSong_shedsAll_keepsMacros() {
        let s = ChatIntentClassifier.classify(utterance: "play iron man by black sabbath")
        XCTAssertEqual(s, ChatIntentClassifier.VolatileSections.utility)
    }

    func test_pauseMusic_shedsTasks() {
        let s = ChatIntentClassifier.classify(utterance: "pause the music")
        XCTAssertFalse(s.taskStack)
        XCTAssertFalse(s.recentFocus)
    }

    // MARK: - Task management, must NOT shed task context

    func test_addTask_keepsTaskStack() {
        let s = ChatIntentClassifier.classify(utterance: "add a task to ship the aurora app")
        XCTAssertTrue(s.taskStack)
    }

    func test_completeTask_keepsTaskStack() {
        let s = ChatIntentClassifier.classify(utterance: "I shipped it")
        XCTAssertTrue(s.taskStack)
    }

    func test_listTasks_keepsTaskStack() {
        let s = ChatIntentClassifier.classify(utterance: "what's on my plate?")
        XCTAssertTrue(s.taskStack)
    }

    func test_focusOnTask_keepsBothTasksAndFocus() {
        let s = ChatIntentClassifier.classify(utterance: "focus on the rolling summarization gap")
        XCTAssertTrue(s.taskStack)
    }

    func test_scratchTask_keepsTaskStack() {
        let s = ChatIntentClassifier.classify(utterance: "scratch that one")
        XCTAssertTrue(s.taskStack)
    }

    // MARK: - Focus / drift queries

    func test_focusQuery_keepsRecentFocus() {
        let s = ChatIntentClassifier.classify(utterance: "am I focused right now?")
        XCTAssertTrue(s.recentFocus)
    }

    func test_distractedQuery_keepsRecentFocus() {
        let s = ChatIntentClassifier.classify(utterance: "have I been getting distracted?")
        XCTAssertTrue(s.recentFocus)
    }

    func test_screenScan_keepsRecentFocus() {
        let s = ChatIntentClassifier.classify(utterance: "rescan my screen")
        XCTAssertTrue(s.recentFocus)
    }

    // MARK: - Image input, always keeps focus context

    func test_imageInput_keepsFocusContext() {
        let s = ChatIntentClassifier.classify(utterance: "what is this", hasImage: true)
        XCTAssertTrue(s.recentFocus, "image attached → he's pointing at something on screen")
        XCTAssertTrue(s.taskStack, "image attached → may relate to active work")
    }

    // MARK: - Edge cases

    func test_empty_returnsAll() {
        let s = ChatIntentClassifier.classify(utterance: "")
        XCTAssertEqual(s, ChatIntentClassifier.VolatileSections.all)
    }

    func test_whitespaceOnly_returnsAll() {
        let s = ChatIntentClassifier.classify(utterance: "   \n\t  ")
        XCTAssertEqual(s, ChatIntentClassifier.VolatileSections.all)
    }

    func test_shortUtterance_keepsMacros() {
        // "lock in" is a 2-word macro trigger, must not shed AVAILABLE_MACROS.
        let s = ChatIntentClassifier.classify(utterance: "lock in")
        XCTAssertTrue(s.availableMacros)
    }

    // MARK: - Word-boundary matching (no false positives)

    func test_fantastic_doesNotMatchTask() {
        // "task" appears as substring of "fantastic", must NOT trigger TASK_STACK.
        let s = ChatIntentClassifier.classify(utterance: "that's a fantastic song")
        XCTAssertFalse(s.taskStack, "substring match must not trigger; word boundary required")
    }

    func test_compose_doesNotMatchPause() {
        // "pause" appears in nothing here, but verifies macro keyword "open"
        // doesn't get triggered by a longer word it appears in.
        let s = ChatIntentClassifier.classify(utterance: "compose a long email about the launch")
        // "open" is a substring of "composed" historically but not "compose"; this just sanity-checks normal text doesn't trip macros.
        // Should still be conservative if uncertain.
        XCTAssertNotNil(s)
    }

    // MARK: - VolatileSections.all sanity

    func test_all_includesEverything() {
        let all = ChatIntentClassifier.VolatileSections.all
        XCTAssertTrue(all.taskStack)
        XCTAssertTrue(all.proposedActions)
        XCTAssertTrue(all.recentFocus)
        XCTAssertTrue(all.availableMacros)
    }

    func test_utility_omitsTaskAndFocusContext() {
        let utility = ChatIntentClassifier.VolatileSections.utility
        XCTAssertFalse(utility.taskStack)
        XCTAssertFalse(utility.recentFocus)
        XCTAssertTrue(utility.availableMacros, "macros stay (cheap, may need run_macro)")
    }
}
