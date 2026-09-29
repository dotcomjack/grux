import XCTest
import SwiftUI
@testable import Grux

/// Found iter 56 (D-replycopy live proof): opening the Chat pane on a thread
/// of 147 messages drew its first three, from hours before, with no Latest
/// chip, so the reply just sent was out of sight. The operator's own snapshot
/// for row 0u was the same top of the same thread. Chat opens on the newest
/// message.
@MainActor
final class ChatOpensAtLatestTests: XCTestCase {

    private var saved: [ChatMessage] = []

    override func setUp() async throws {
        saved = AppState.shared.chat
    }

    override func tearDown() async throws {
        AppState.shared.chat = saved
    }

    /// Two threads of the same length that differ only in their last three
    /// messages. Opened at the latest, the two transcripts draw differently;
    /// opened at the top, they draw the same pixels.
    func test_chatOpensOnTheLatestMessage() throws {
        let head = (0..<60).map { ChatMessage(role: .user, content: "u\($0)") }
        let a = try render(head + (0..<3).map { ChatMessage(role: .user, content: "u\(60 + $0)") })
        let b = try render(head + (0..<3).map { ChatMessage(role: .assistant, content: "Grux reply number \($0)") })
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        var differing = 0
        // The transcript band, under the header and above the composer, whose
        // readiness notice lands asynchronously and differs between renders.
        let band = Int(Double(a.pixelsHigh) * 0.16)..<Int(Double(a.pixelsHigh) * 0.55)
        for y in band {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let d = abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent)
                if d > 0.15 { differing += 1 }
            }
        }
        XCTAssertGreaterThan(differing, 500,
                             "Chat opened away from the latest message: the last three messages drew nothing (\(differing) px differ)")
    }

    private func render(_ thread: [ChatMessage]) throws -> NSBitmapImageRep {
        AppState.shared.chat = thread
        let size = NSSize(width: 680, height: 560)
        let host = NSHostingView(rootView: ChatView()
            .frame(width: size.width, height: size.height)
            .background(GruxTheme.base)
            .environmentObject(AppState.shared))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // Closed, so no window a test opened is left for a later test.
        // (`isReleasedWhenClosed` is off, so closing does not release it twice.)
        window.contentView = nil
        window.close()
        return rep
    }

    // MARK: - SWEEP-11: the pane grows as it opens

    /// A pane that opens narrow and grows, as the Command Panel's window does
    /// when its pane opens (an animated width change).
    private final class PaneSize: ObservableObject {
        @Published var width: CGFloat
        @Published var height: CGFloat = 560
        init(_ width: CGFloat) { self.width = width }
    }

    private struct GrowingPane: View {
        @ObservedObject var size: PaneSize
        var body: some View {
            ChatView()
                .frame(width: size.width, height: size.height)
                .background(GruxTheme.base)
                .environmentObject(AppState.shared)
                .frame(width: max(680, size.width), height: max(560, size.height), alignment: .topLeading)
        }
    }

    /// The render, whether the Latest chip is up (its own state, what decides
    /// whether it draws), and whether the transcript's end is in view (its
    /// geometry). Both are read from this Chat's own transcript.
    private func renderGrowing(_ thread: [ChatMessage], from startWidth: CGFloat) throws
        -> (NSBitmapImageRep, chip: Bool, atEnd: Bool) {
        AppState.shared.chat = thread
        let size = PaneSize(startWidth)
        let host = NSHostingView(rootView: GrowingPane(size: size))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        func spin(_ t: Double) {
            let deadline = Date().addingTimeInterval(t)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(0.8)
        for step in 1...8 {
            size.width = startWidth + (680 - startWidth) * CGFloat(step) / 8
            spin(0.03)
        }
        spin(1.5)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let transcript = try XCTUnwrap(scrollViews(in: host).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let chip = ChatView.latestChipShown(in: transcript) ?? true
        let doc = transcript.documentView?.frame.height ?? 0
        let visible = transcript.contentView.bounds
        let atEnd = (transcript.documentView?.isFlipped ?? true) ? visible.maxY >= doc - 8 : visible.minY <= 8
        window.contentView = nil
        window.close()
        return (rep, chip, atEnd)
    }

    /// SWEEP-11 (`s11-chat-re2`): after the workflow runs put long gate lines
    /// in the thread, Chat drew an empty transcript with the Latest chip up,
    /// while the thread ended "Six plus five is eleven.". The bottom anchor
    /// only placed the first layout; the pane opening narrow and growing
    /// re-wrapped every long line and nothing put the newest message back in
    /// view. Opened narrow or wide, the newest message is drawn and the chip
    /// is down.
    func test_chatOpenedAsThePaneGrowsShowsTheLatestMessage() throws {
        let gate = "ship the iOS app: Dry run: the steps before this were only recorded, nothing was opened or "
            + "changed. The plan is ready. Reply go to start building it, or tell me what to change."
        var head: [ChatMessage] = [ChatMessage(role: .user, content: "what is nine plus four"),
                                   ChatMessage(role: .assistant, content: "Nine plus four is thirteen.")]
        for _ in 0..<7 { head.append(ChatMessage(role: .assistant, content: gate)) }
        head.append(ChatMessage(role: .assistant, content: String(repeating: "TestFlight feedback for your project: "
            + "Should I fix what your TestFlight testers reported before it goes to the App Store?\n\n", count: 4) + "Got it."))
        head.append(ChatMessage(role: .user, content: "what is six plus five"))
        // The "no model" notice settles asynchronously and moves the
        // transcript; one warm-up render lets it settle before comparing.
        _ = try renderGrowing(head + [ChatMessage(role: .assistant, content: "warm up")], from: 680)
        for start: CGFloat in [120, 300, 680] {
            let (a, chipA, endA) = try renderGrowing(head + [ChatMessage(role: .assistant, content: "Six plus five is eleven.")], from: start)
            let (b, chipB, endB) = try renderGrowing(head + [ChatMessage(role: .assistant, content: "Grux says something else entirely here.")],
                                                     from: start)
            // The geometry and the chip separately: a stale chip is up over a
            // transcript whose end is in view, and only the chip's own state
            // shows that.
            XCTAssertTrue(endA && endB, "opened from \(start)pt: the transcript's end is out of view")
            XCTAssertFalse(chipA || chipB, "opened from \(start)pt: the Latest chip is up, so the newest message is out of view")
            var differing = 0
            var drawn = 0
            let band = Int(Double(a.pixelsHigh) * 0.16)..<Int(Double(a.pixelsHigh) * 0.52)
            for y in band {
                for x in 0..<a.pixelsWide {
                    guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let d = abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                        + abs(p.blueComponent - q.blueComponent)
                    if d > 0.15 { differing += 1 }
                    if x > a.pixelsWide / 2, p.redComponent + p.greenComponent + p.blueComponent > 1.5 { drawn += 1 }
                }
            }
            XCTAssertGreaterThan(drawn, 500, "opened from \(start)pt: the transcript is empty")
            XCTAssertGreaterThan(differing, 300, "opened from \(start)pt: the newest message drew nothing (\(differing) px differ)")
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// The Latest chip still comes up when the person scrolls up to read,
    /// and goes when they are back at the newest message. Its visibility now
    /// comes from where the bottom of the transcript sits, not from rows
    /// appearing, so this proves the chip was not simply switched off.
    func test_scrollingUpToReadBringsTheLatestChipAndScrollingBackTakesItAway() throws {
        // Long enough that one page of them is several screens tall.
        AppState.shared.chat = (0..<60).map {
            ChatMessage(role: $0 % 2 == 0 ? .user : .assistant,
                        content: "message \($0). " + String(repeating: "More words to make it a few lines long. ", count: 5))
        }
        let size = NSSize(width: 680, height: 560)
        let host = NSHostingView(rootView: ChatView()
            .frame(width: size.width, height: size.height)
            .background(GruxTheme.base)
            .environmentObject(AppState.shared))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func spin(_ t: Double) {
            let deadline = Date().addingTimeInterval(t)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(1.5)
        let transcript = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertEqual(ChatView.latestChipShown(in: transcript), false, "opened away from the newest message")
        let docHeight = transcript.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(docHeight, size.height * 2, "the transcript is not the tall scroll view")
        func scroll(toTop top: Bool) {
            let flipped = transcript.documentView?.isFlipped ?? true
            let visible = transcript.contentView.bounds.height
            let y: CGFloat = (top == flipped) ? 0 : max(0, docHeight - visible)
            transcript.contentView.scroll(to: NSPoint(x: 0, y: y))
            transcript.reflectScrolledClipView(transcript.contentView)
            spin(0.8)
        }
        scroll(toTop: true)
        XCTAssertEqual(ChatView.latestChipShown(in: transcript), true, "scrolled up to the first message and the Latest chip did not come up")
        scroll(toTop: false)
        XCTAssertEqual(ChatView.latestChipShown(in: transcript), false, "back at the newest message and the Latest chip stayed up")
    }

    // MARK: - A long thread lays out only its newest messages

    /// Measured before the install (lead, 2026-09-28): the whole-thread
    /// VStack opened a 500-message thread in 1715 ms and 220 MB; one page of
    /// 16 opens it in 128 ms and 10 MB (85 ms for an empty thread), and
    /// nothing bounds a thread (compaction needs a model route; loading a
    /// thread sets every message). The transcript lays out the newest page,
    /// with "Show earlier" for the rest.
    func test_theTranscriptWindowIsTheNewestPageAndShowEarlierAddsAPage() {
        let chat = (0..<500).map { ChatMessage(role: .user, content: "m\($0)") }
        let page = ChatView.transcriptPage
        var w = ChatView.transcriptWindow(chat, shown: page)
        XCTAssertEqual(w.earlier, 500 - page)
        XCTAssertEqual(w.messages.map(\.id), chat.suffix(page).map(\.id))
        w = ChatView.transcriptWindow(chat, shown: page * 2)
        XCTAssertEqual(w.earlier, 500 - page * 2)
        XCTAssertEqual(w.messages.first?.content, "m\(500 - page * 2)")
        w = ChatView.transcriptWindow(Array(chat.prefix(10)), shown: page)
        XCTAssertEqual(w.earlier, 0)
        XCTAssertEqual(w.messages.count, 10)
    }

    /// The same, in the real view: a 500-message thread's transcript content
    /// is about one page tall, not five hundred messages tall.
    func test_aLongThreadOpensWithOnlyItsNewestPageLaidOut() throws {
        AppState.shared.chat = (0..<500).map {
            ChatMessage(role: $0 % 2 == 0 ? .user : .assistant,
                        content: String(repeating: "A reply that runs to a couple of lines in the transcript. ", count: 3))
        }
        let size = NSSize(width: 680, height: 560)
        let host = NSHostingView(rootView: ChatView()
            .frame(width: size.width, height: size.height)
            .background(GruxTheme.base)
            .environmentObject(AppState.shared))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let tallest = scrollViews(in: host).map { $0.documentView?.frame.height ?? 0 }.max() ?? 0
        XCTAssertGreaterThan(tallest, size.height, "no transcript was laid out")
        XCTAssertLessThan(tallest, CGFloat(ChatView.transcriptPage + 2) * 140,
                          "the transcript laid out far more than one page: \(Int(tallest)) pt")
    }

    // MARK: - Only the person's own scrolling decides whether Chat follows

    /// A hosted Chat whose pane size the test changes, with its transcript's
    /// scroll view.
    private func hostPane(_ thread: [ChatMessage], width: CGFloat = 680, height: CGFloat = 560) throws
        -> (window: NSWindow, host: NSView, size: PaneSize, transcript: NSScrollView) {
        AppState.shared.chat = thread
        let size = PaneSize(width)
        size.height = height
        let host = NSHostingView(rootView: GrowingPane(size: size))
        host.frame = NSRect(x: 0, y: 0, width: max(680, width), height: max(560, height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.05)
        // Closed after the test, so no window it opened is left for a later one.
        addTeardownBlock { window.contentView = nil; window.close() }
        let transcript = try XCTUnwrap(scrollViews(in: host).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        return (window, host, size, transcript)
    }

    private func pump(_ t: Double) {
        let deadline = Date().addingTimeInterval(t)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// What a person's trackpad scroll to the top is: the scroll view
    /// reporting the start of a live scroll, the view moving to the top, and
    /// the end of the live scroll.
    /// (Synthesized scroll-wheel events do not move an offscreen scroll
    /// view, so the clip view is moved the way the scroll ends up.)
    private func personScrollsToTop(_ transcript: NSScrollView) {
        let flipped = transcript.documentView?.isFlipped ?? true
        let doc = transcript.documentView?.frame.height ?? 0
        let visible = transcript.contentView.bounds.height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: transcript)
        transcript.contentView.scroll(to: NSPoint(x: 0, y: flipped ? 0 : max(0, doc - visible)))
        transcript.reflectScrolledClipView(transcript.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: transcript)
    }

    private func longThread() -> [ChatMessage] {
        (0..<40).map {
            ChatMessage(role: $0 % 2 == 0 ? .user : .assistant,
                        content: "message \($0). " + String(repeating: "More words to make it a few lines long. ", count: 5))
        }
    }

    /// Review of 12eda8a, P2: a scroll-up within 0.6 s of a viewport change
    /// was ignored and never re-checked, so the next composer growth pulled
    /// the person back to the bottom. Scroll up 0.1 s after opening, then the
    /// transcript's viewport shrinks (the composer growing): they stay up.
    func test_aScrollUpRightAfterOpeningSurvivesTheComposerGrowing() throws {
        let pane = try hostPane(longThread())
        defer { pane.window.contentView = nil }
        pump(0.1)
        personScrollsToTop(pane.transcript)
        pump(0.1)
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), false, "the person's scroll-up did not turn following off")
        pane.size.height = 420
        pump(1.0)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), true, "the composer growing took the person back to the bottom")
    }

    /// Review of 12eda8a, P2: during a window drag-resize every scroll-up was
    /// inside the settle window, so it could not stick.
    func test_aScrollUpDuringAResizeStays() throws {
        // Above Chat's minimum width, so every step really resizes the
        // transcript, a tenth of a second apart, as a drag does.
        let pane = try hostPane(longThread(), width: 600)
        defer { pane.window.contentView = nil }
        pump(0.8)
        for step in 1...10 {
            pane.size.width = 600 + 8 * CGFloat(step)
            pump(0.1)
            if step == 5 {
                personScrollsToTop(pane.transcript)
                let flipped = pane.transcript.documentView?.isFlipped ?? true
                XCTAssertEqual(flipped ? pane.transcript.contentView.bounds.minY : 0, 0, accuracy: 4,
                               "control: the scroll-wheel input reached the top")
            }
        }
        pump(1.0)
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), false, "the person's scroll-up during the resize did not turn following off")
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), true, "the scroll-up made during the resize did not stick")
    }

    /// Review of 12eda8a, P3: the thinking bubble appearing must not read as
    /// the person scrolling up. While following, the view stays at the
    /// bottom with the bubble in it, and following stays on. (Offscreen the
    /// old code passed this too; it guards the case, it never failed.)
    func test_theThinkingBubbleKeepsAFollowingTranscriptAtTheBottom() throws {
        let pane = try hostPane(longThread())
        defer {
            pane.window.contentView = nil
            AppState.shared.isThinking = false
        }
        pump(1.0)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "control: opened at the newest message")
        AppState.shared.isThinking = true
        pump(1.0)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "the thinking bubble moved the view off the bottom")
        // And a resize after it still re-anchors: following was not turned off.
        pane.size.height = 420
        pump(1.0)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "following was turned off by the bubble")
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), true)
    }

    // MARK: - Review of d6cd37d

    /// The chip is set on the next turn from where the view is. It read the
    /// view when it was moved and set that value later, and skipped a move
    /// whose value matched the not-yet-set chip, so in a burst of moves (as
    /// a pane grows) a stale "not at the end" landed last: the chip stayed
    /// up over a transcript showing its end. Two moves in one turn, off the
    /// end and back, leave the chip down.
    func test_aBurstOfMovesThatEndsAtTheEndLeavesTheChipDown() throws {
        let pane = try hostPane(longThread())
        defer { pane.window.contentView = nil }
        pump(1.0)
        let doc = try XCTUnwrap(pane.transcript.documentView)
        let clip = pane.transcript.contentView
        let end = clip.bounds.minY
        XCTAssertGreaterThanOrEqual(clip.bounds.maxY, doc.frame.height - 8, "control: opened at the end")
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "control: the chip is down at the end")
        // Control: a move off the end on its own brings the chip up.
        clip.scroll(to: NSPoint(x: 0, y: end - 400))
        pane.transcript.reflectScrolledClipView(clip)
        pump(0.3)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), true, "control: off the end, the chip came up")
        clip.scroll(to: NSPoint(x: 0, y: end))
        pane.transcript.reflectScrolledClipView(clip)
        pump(0.3)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "control: back at the end, the chip went down")
        // The burst: off the end and back within one turn.
        clip.scroll(to: NSPoint(x: 0, y: end - 400))
        pane.transcript.reflectScrolledClipView(clip)
        clip.scroll(to: NSPoint(x: 0, y: end))
        pane.transcript.reflectScrolledClipView(clip)
        pump(0.5)
        XCTAssertGreaterThanOrEqual(clip.bounds.maxY, doc.frame.height - 8, "the view is not at the end")
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false,
                       "a stale \"not at the end\" landed last: the chip is up over the transcript's end")
    }

    /// P2: while not following, every bounds change that was not a wheel or
    /// live scroll was put back, so selection drag autoscroll jittered and
    /// VoiceOver or a focused field could not move the view. A move that is
    /// not a layout is the person's new place.
    func test_aNonWheelScrollWhileNotFollowingIsKept() throws {
        let pane = try hostPane(longThread())
        defer { pane.window.contentView = nil }
        pump(1.0)
        personScrollsToTop(pane.transcript)
        pump(0.5)
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), false, "control: the scroll-up turned following off")
        // Selection autoscroll, VoiceOver, a focused field: the view moves
        // with no wheel and no live scroll.
        let clip = pane.transcript.contentView
        clip.scroll(to: NSPoint(x: 0, y: 300))
        pane.transcript.reflectScrolledClipView(clip)
        pump(0.5)
        XCTAssertEqual(clip.bounds.minY, 300, accuracy: 2, "a move that was not a wheel or a live scroll was taken back")
        // And it is the person's place now: a later layout keeps it.
        pane.size.height = 420
        pump(0.8)
        XCTAssertEqual(clip.bounds.minY, 300, accuracy: 2, "a layout took the person back to their old place")
    }

    /// P3: a queued re-anchor took back the first tick of a person's scroll.
    /// While their live scroll runs, nothing re-anchors.
    func test_aReanchorWaitsWhileThePersonIsScrolling() throws {
        let pane = try hostPane(longThread())
        defer { pane.window.contentView = nil }
        pump(1.0)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "control: opened at the newest message")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: pane.transcript)
        let clip = pane.transcript.contentView
        let startY = clip.bounds.minY
        clip.scroll(to: NSPoint(x: 0, y: max(0, startY - 200)))
        pane.transcript.reflectScrolledClipView(clip)
        pane.size.height = 420
        pump(0.6)
        XCTAssertEqual(clip.bounds.minY, max(0, startY - 200), accuracy: 2,
                       "a re-anchor took back the person's scroll while it was still going")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: pane.transcript)
        pump(0.3)
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), false)
    }

    /// P3: switching threads reset the page but not following, so the next
    /// thread opened at the old thread's held place.
    func test_switchingThreadsOpensTheOtherThreadAtItsNewestMessage() throws {
        let savedThread = AppState.shared.activeThreadId
        defer { AppState.shared.activeThreadId = savedThread }
        let pane = try hostPane(longThread())
        defer { pane.window.contentView = nil }
        pump(1.0)
        personScrollsToTop(pane.transcript)
        pump(0.5)
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), true, "control: scrolled up")
        AppState.shared.activeThreadId = UUID()
        AppState.shared.chat = longThread()
        pump(1.0)
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), true, "the other thread did not follow its newest message")
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "the other thread opened away from its newest message")
    }

    /// Tapping "Show earlier" shows a page more
    /// above, keeps the message that was on top where the person reads, and
    /// leaves following off, so a later layout does not send them down.
    func test_tappingShowEarlierKeepsTheTopMessageInPlace() throws {
        let pane = try hostPane(longThread())
        defer { pane.window.contentView = nil }
        pump(1.0)
        personScrollsToTop(pane.transcript)
        pump(0.5)
        let doc = try XCTUnwrap(pane.transcript.documentView)
        let clip = pane.transcript.contentView
        let before = doc.frame.height
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 2, "control: at the top, where the Show earlier row is")
        try tapShowEarlier(pane)
        pump(1.0)
        let added = doc.frame.height - before
        XCTAssertGreaterThan(added, 300, "the tap on Show earlier showed nothing more")
        // The message that was on top is at the top again, a page further down.
        XCTAssertEqual(clip.bounds.minY, added, accuracy: 60, "the message that was on top did not stay where the person reads")
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), false, "Show earlier left following on")
        let kept = clip.bounds.minY
        pane.size.height = 420
        pump(0.8)
        XCTAssertEqual(clip.bounds.minY, kept, accuracy: 2, "a layout after Show earlier sent the person elsewhere")
    }

    /// P3 (review of d6cd37d): Show earlier left following on, so when all
    /// of a short thread fit, the next layout after the tap sent the person
    /// to the newest message instead of keeping the message they tapped
    /// above. A tall pane where the newest page fits: tap Show earlier, then
    /// the pane shrinks, and the view stays where the tap left it.
    func test_showEarlierTurnsFollowingOffSoALaterLayoutKeepsThePlace() throws {
        let thread = (0..<20).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "m\($0)") }
        let pane = try hostPane(thread, height: 1600)
        defer { pane.window.contentView = nil }
        pump(1.0)
        let doc = try XCTUnwrap(pane.transcript.documentView)
        let clip = pane.transcript.contentView
        XCTAssertLessThanOrEqual(doc.frame.height, clip.bounds.height + 1, "control: the newest page fits the tall pane")
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), true, "control: a thread that fits follows its newest message")
        let before = doc.frame.height
        try tapShowEarlier(pane)
        pump(1.0)
        XCTAssertGreaterThan(doc.frame.height, before, "control: the tap on Show earlier showed more")
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), false, "Show earlier left following on")
        pane.size.height = 360
        pump(1.0)
        XCTAssertGreaterThan(doc.frame.height, clip.bounds.height + 100, "control: the smaller pane no longer fits the thread")
        // The place is a message, not an offset (SWEEP-13): the message that
        // was first before the tap is at the top, and the view is nowhere
        // near the newest message.
        let s = ChatView.status(of: pane.transcript)
        XCTAssertEqual(s["topVisibleMessageId"] as? String, thread[thread.count - ChatView.transcriptPage].id.uuidString,
                       "a layout after Show earlier moved the message the tap kept at the top")
        XCTAssertLessThan((s["scrollOffset"] as? Double) ?? .infinity, ((s["scrollMax"] as? Double) ?? 0) - 100,
                          "a layout after Show earlier sent the person to the newest message")
        XCTAssertEqual(s["followsLatest"] as? Bool, false)
    }

    /// A tap on the transcript's "Show earlier" row: the same function its
    /// button runs. (A synthesized click never reaches the row in an offscreen
    /// window, measured on the Mini, and a test must not show a window.)
    private func tapShowEarlier(_ pane: (window: NSWindow, host: NSView, size: PaneSize, transcript: NSScrollView)) throws {
        XCTAssertTrue(ChatView.perform(.showEarlier, in: pane.transcript), "no Chat owns the test's transcript")
    }

    /// Found by the Latest trigger's test: an animated scroll Chat starts
    /// (a new message, the Latest chip) lands 33 pt short of the end, and its
    /// last frames came after the move's window closed, so they were taken as
    /// the person's own place: following went off and the chip stayed up. A
    /// new message while following leaves the view at the end, following.
    func test_aNewMessageKeepsAFollowingTranscriptAtTheEnd() throws {
        var thread = longThread()
        let pane = try hostPane(thread)
        pump(1.0)
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), true, "control: opened following")
        thread.append(ChatMessage(role: .assistant, content: "A new reply. " + String(repeating: "More words. ", count: 12)))
        AppState.shared.chat = thread
        pump(1.5)
        let doc = try XCTUnwrap(pane.transcript.documentView)
        let clip = pane.transcript.contentView
        XCTAssertEqual(ChatView.followsLatest(in: pane.transcript), true, "a new message turned following off")
        XCTAssertEqual(ChatView.latestChipShown(in: pane.transcript), false, "the Latest chip is up after a new message")
        XCTAssertGreaterThanOrEqual(clip.bounds.maxY, doc.frame.height - 8, "the view is not at the end")
    }

    // MARK: - Chat triggers (SWEEP-12: Show earlier, a scroll and Latest had no door but a mouse)

    /// Drops `name` (with `contents`) in a folder of the test's own, runs the
    /// app's registration of the chat triggers on it, and returns the
    /// chat-status.json the trigger writes.
    private func fireChatTrigger(_ name: String, _ contents: String = "") throws -> [String: Any] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-triggers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = TriggerWatcher(directory: dir)
        ChatTriggers.register(in: dir, on: watcher)
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        watcher.sweepNow()
        let status = dir.appendingPathComponent(ChatTriggers.statusFile)
        let deadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: status.path), Date() < deadline { pump(0.05) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "the trigger file was not taken")
        let data = try Data(contentsOf: status)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ status: [String: Any], _ key: String) -> Double { (status[key] as? NSNumber)?.doubleValue ?? .nan }

    func test_fireChatStatusDescribesTheTranscriptAndChangesNothing() throws {
        let thread = longThread()
        let pane = try hostPane(thread)
        pump(1.0)
        let before = pane.transcript.contentView.bounds.minY
        let status = try fireChatTrigger(ChatTriggers.status)
        XCTAssertEqual(status["chatOpen"] as? Bool, true)
        XCTAssertEqual(status["totalMessages"] as? Int, thread.count)
        XCTAssertEqual(status["shownCount"] as? Int, ChatView.transcriptPage)
        XCTAssertEqual(status["followsLatest"] as? Bool, true)
        XCTAssertEqual(status["latestChipUp"] as? Bool, false)
        XCTAssertEqual(number(status, "scrollOffset"), number(status, "scrollMax"), accuracy: 2, "opened at the end")
        let top = try XCTUnwrap(status["topVisibleMessageId"] as? String)
        XCTAssertTrue(thread.suffix(ChatView.transcriptPage).contains { $0.id.uuidString == top }, "the top message is not one laid out")
        XCTAssertEqual(pane.transcript.contentView.bounds.minY, before, "the status trigger moved the view")
    }

    func test_fireChatScrollMovesTheViewAsAPersonsScrollDoes() throws {
        let pane = try hostPane(longThread())
        pump(1.0)
        let before = try fireChatTrigger(ChatTriggers.status)
        let status = try fireChatTrigger(ChatTriggers.scroll, "-600")
        XCTAssertEqual(number(status, "scrollOffset"), number(before, "scrollOffset") - 600, accuracy: 2, "the view did not move up 600 pt")
        XCTAssertEqual(status["followsLatest"] as? Bool, false, "a scroll up did not turn following off")
        XCTAssertEqual(status["latestChipUp"] as? Bool, true, "the Latest chip did not come up")
        XCTAssertNotEqual(status["topVisibleMessageId"] as? String, before["topVisibleMessageId"] as? String)
        XCTAssertEqual(pane.transcript.contentView.bounds.minY, CGFloat(number(status, "scrollOffset")), accuracy: 1,
                       "the status file does not say where the view is")
    }

    func test_fireChatShowEarlierShowsAPageMoreAndKeepsTheTopMessage() throws {
        let thread = longThread()
        _ = try hostPane(thread)
        pump(1.0)
        let atTop = try fireChatTrigger(ChatTriggers.scroll, "-100000")
        XCTAssertEqual(number(atTop, "scrollOffset"), 0, accuracy: 1, "control: the scroll reached the top")
        let firstShown = thread[thread.count - ChatView.transcriptPage].id.uuidString
        XCTAssertEqual(atTop["topVisibleMessageId"] as? String, firstShown, "control: the first message laid out is on top")
        let status = try fireChatTrigger(ChatTriggers.showEarlier)
        XCTAssertEqual(status["shownCount"] as? Int, 2 * ChatView.transcriptPage, "Show earlier added no page")
        XCTAssertEqual(status["topVisibleMessageId"] as? String, firstShown, "the message that was on top did not stay there")
        XCTAssertGreaterThan(number(status, "scrollOffset"), 300, "the view stayed at the top of the new page")
        XCTAssertEqual(status["followsLatest"] as? Bool, false)
    }

    func test_fireChatLatestGoesBackToTheNewestMessage() throws {
        _ = try hostPane(longThread())
        pump(1.0)
        let up = try fireChatTrigger(ChatTriggers.scroll, "-800")
        XCTAssertEqual(up["latestChipUp"] as? Bool, true, "control: scrolled up, the chip is up")
        let status = try fireChatTrigger(ChatTriggers.latest)
        XCTAssertEqual(status["followsLatest"] as? Bool, true, "Latest did not turn following back on")
        XCTAssertEqual(status["latestChipUp"] as? Bool, false, "the Latest chip is still up")
        XCTAssertEqual(number(status, "scrollOffset"), number(status, "scrollMax"), accuracy: 2, "the view is not at the end")
    }

    func test_firePaneWidthResizesThePaneChatIsIn() throws {
        let pane = try hostPane(longThread())
        pump(1.0)
        let saved = ChatTriggers.setPaneWidth
        defer { ChatTriggers.setPaneWidth = saved }
        ChatTriggers.setPaneWidth = { pane.size.width = $0 }
        let wide = try fireChatTrigger(ChatTriggers.status)
        let status = try fireChatTrigger(ChatTriggers.paneWidth, "600")
        XCTAssertEqual(pane.size.width, 600, "the pane was not set to 600 pt")
        XCTAssertEqual(number(wide, "transcriptWidth") - number(status, "transcriptWidth"), 80, accuracy: 1,
                       "the transcript did not narrow with the pane")
    }

    /// The app registers the chat triggers with the rest (the tests above run
    /// the same registration on a folder of their own).
    func test_theAppRegistersTheChatTriggers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let triggers = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Triggers/AppTriggers.swift"), encoding: .utf8)
        XCTAssertTrue(triggers.contains("ChatTriggers.register(in: dir)"), "the chat triggers are never registered")
        XCTAssertEqual(ChatTriggers.names, ["fire-chat-show-earlier", "fire-chat-scroll", "fire-chat-latest",
                                            "fire-chat-status", "fire-pane-width"], "a trigger file name changed")
    }

    /// Review of 66ea148, P3: "nan" scrolled to the top (max(0, NaN) is 0),
    /// and "inf" is not a distance either. Neither moves the view.
    func test_fireChatScrollRefusesANumberThatIsNotFinite() throws {
        let pane = try hostPane(longThread())
        pump(1.0)
        let before = pane.transcript.contentView.bounds.minY
        XCTAssertGreaterThan(before, 100, "control: opened away from the top")
        for bad in ["nan", "inf", "-inf", "up"] {
            let status = try fireChatTrigger(ChatTriggers.scroll, bad)
            XCTAssertEqual(number(status, "scrollOffset"), Double(before), accuracy: 1, "\(bad) moved the view")
        }
        let moved = try fireChatTrigger(ChatTriggers.scroll, "-200")
        XCTAssertEqual(number(moved, "scrollOffset"), Double(before) - 200, accuracy: 2, "control: a finite scroll still moves it")
    }

    /// Review of 66ea148, P3: "inf" or 1e9 reached the window sizer. A width
    /// that is not finite or not positive is refused, and the rest is
    /// clamped between the window's floor and what the screen can show.
    func test_firePaneWidthRefusesAWidthThatIsNotFiniteAndClampsToTheScreen() throws {
        _ = try hostPane(longThread())
        pump(0.5)
        let saved = ChatTriggers.setPaneWidth
        defer { ChatTriggers.setPaneWidth = saved }
        var asked: [CGFloat] = []
        ChatTriggers.setPaneWidth = { asked.append($0) }
        for bad in ["inf", "nan", "-400", "0", "wide"] { _ = try fireChatTrigger(ChatTriggers.paneWidth, bad) }
        XCTAssertEqual(asked, [], "a width that is not a finite positive number reached the sizer")
        _ = try fireChatTrigger(ChatTriggers.paneWidth, "640")
        XCTAssertEqual(asked, [640], "control: a real width still does")
        let panel = GruxLayout.panelWidth + 1
        XCTAssertEqual(ChatTriggers.contentWidth(forPane: 1e9, floor: 700, screen: 1440, chrome: 0), 1440, "not clamped to the screen")
        XCTAssertEqual(ChatTriggers.contentWidth(forPane: 1e9, floor: 700, screen: 1440, chrome: 12), 1428, "the frame's chrome is not left room")
        XCTAssertEqual(ChatTriggers.contentWidth(forPane: 10, floor: 700, screen: 1440, chrome: 0), 700, "went under the floor")
        XCTAssertEqual(ChatTriggers.contentWidth(forPane: 500, floor: 300, screen: 1440, chrome: 0), panel + 500)
    }

    /// Review of 66ea148, P3: the live Chat stayed the trigger target after
    /// it left its window, so chat-status.json said a Chat was open.
    func test_aChatThatLeftItsWindowIsNoLongerTheLiveOne() throws {
        let pane = try hostPane(longThread())
        pump(1.0)
        XCTAssertEqual(try fireChatTrigger(ChatTriggers.status)["chatOpen"] as? Bool, true, "control: the Chat is open")
        pane.window.contentView = nil
        pump(0.3)
        let status = try fireChatTrigger(ChatTriggers.status)
        XCTAssertEqual(status["chatOpen"] as? Bool, false, "a Chat no longer in a window is still reported open")
        XCTAssertFalse(ChatView.perform(.latest), "a trigger still acts on a Chat no longer in a window")
    }

    // MARK: - SWEEP-13, measured live through the chat triggers

    /// Waits until the transcript stops moving (at least 0.35 s, at most 3 s).
    private func settle(_ transcript: NSScrollView) {
        pump(0.35)
        let deadline = Date().addingTimeInterval(3)
        while !ChatView.isSettled(transcript), Date() < deadline { pump(0.05) }
    }

    /// SWEEP-13: scrolled up at 1100 pt with message 14 on top, a resize to
    /// 700 kept the pixel offset (902) while every message above re-wrapped
    /// taller, and the top became message 11. A resize keeps the message the
    /// reader was on at the top, at each width the sweep used.
    func test_aResizeKeepsTheMessageTheReaderWasOnAtTheTop() throws {
        let pane = try hostPane(longThread(), width: 1100)
        pump(1.0)
        // Up to about 40% of the way down, as the sweep was (902 of 2252).
        let end = (ChatView.status(of: pane.transcript)["scrollMax"] as? Double) ?? 0
        ChatView.perform(.scroll(-CGFloat(end * 0.6)), in: pane.transcript)
        settle(pane.transcript)
        let before = ChatView.status(of: pane.transcript)
        XCTAssertEqual(before["followsLatest"] as? Bool, false, "control: scrolled up, not following")
        XCTAssertGreaterThan((before["scrollOffset"] as? Double) ?? 0, 200, "control: the reader is mid-thread, not at the top")
        let top = try XCTUnwrap(before["topVisibleMessageId"] as? String)
        for width: CGFloat in [700, 900, 1100, 700] {
            pane.size.width = width
            pump(1.2)
            settle(pane.transcript)
            let now = ChatView.status(of: pane.transcript)
            XCTAssertEqual(now["topVisibleMessageId"] as? String, top, "at \(Int(width)) pt the reader's message moved off the top")
            XCTAssertEqual(now["followsLatest"] as? Bool, false, "at \(Int(width)) pt a resize turned following on")
        }
    }

    /// SWEEP-13: Latest stopped 33 pt short, following off and the chip up,
    /// 2 of 8 tries live (1100 pt, after Show earlier, scroll up 500 then
    /// Latest). Twenty tries, each ending at the end, following, chip down.
    func test_latestEndsAtTheEndFollowingEveryTime() throws {
        let pane = try hostPane(longThread(), width: 1100)
        pump(1.0)
        ChatView.perform(.showEarlier, in: pane.transcript)
        settle(pane.transcript)
        var misses: [String] = []
        for attempt in 1...20 {
            ChatView.perform(.scroll(-500), in: pane.transcript)
            settle(pane.transcript)
            ChatView.perform(.latest, in: pane.transcript)
            settle(pane.transcript)
            let s = ChatView.status(of: pane.transcript)
            let offset = (s["scrollOffset"] as? Double) ?? -1, end = (s["scrollMax"] as? Double) ?? -2
            if s["followsLatest"] as? Bool != true || s["latestChipUp"] as? Bool != false || abs(offset - end) > 2 {
                misses.append("try \(attempt): following \(s["followsLatest"] ?? "?"), chip \(s["latestChipUp"] ?? "?"), \(Int(offset)) of \(Int(end))")
            }
        }
        XCTAssertEqual(misses, [], "Latest did not end at the end, following")
    }
}
