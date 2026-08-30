import XCTest
@testable import Grux
import GruxShellCore

/// Empty states are the first thing a new user reads on a tab, and they are the
/// easiest copy in the app to write badly, because whoever writes it is looking
/// at a screen full of their own data and never sees it.
///
/// The rule this file enforces is the one the chat suggestion chips established:
/// NEVER INSTRUCT SOMETHING THE USER CANNOT ACT ON. An empty state has one job,
/// which is to teach what the surface is for and how to get something into it.
@MainActor
final class EmptyStateCopyTests: XCTestCase {

    // MARK: - Projects

    /// THE BUG. A new user has no registry and no cached copy, so
    /// `registrySource` is `.empty`, and the tab greeted them with "The project
    /// registry is unreachable and no cached copy is on disk" followed by
    /// "Start the project registry at http://localhost:3847 or scaffold a Grux
    /// project."
    ///
    /// Three things wrong at once: it reports an internal component as broken
    /// when nothing is, it tells a stranger to start a server they have never
    /// heard of on a port they cannot know, and it never says what a project
    /// actually is. `endpointRegistry` is OPTIONAL in the feature registry, so
    /// Projects is deliberately ungated and this was the first thing anybody saw
    /// on the tab.
    func testProjectsEmptyStateDoesNotTellAStrangerToStartAServer() {
        let copy = ProjectsView.emptyCopy(registryMissing: true)
        let all = [copy.title, copy.body, copy.note ?? ""].joined(separator: " ").lowercased()

        XCTAssertFalse(all.contains("start the project registry"),
                       "a new user cannot start a server and should not be told to")
        XCTAssertFalse(all.contains("unreachable"),
                       "nothing is broken when an optional component is simply absent, and saying so reads as a fault")
        XCTAssertFalse(all.contains("localhost:"),
                       "a port number is not an instruction anybody outside this repo can act on")
    }

    /// The other half. Removing bad copy is only half a fix; the surface still
    /// has to teach what it is for.
    func testProjectsEmptyStateTeachesWhatAProjectActuallyIs() {
        let copy = ProjectsView.emptyCopy(registryMissing: true)
        let all = [copy.title, copy.body, copy.note ?? ""].joined(separator: " ")

        XCTAssertTrue(all.contains(".grux/project.json"),
                      "the one thing that makes a folder a project has to be named")
        XCTAssertTrue(all.contains("~/Projects"),
                      "and where Grux looks, or the reader cannot act on it")
    }

    /// The scan roots are read from the source of truth rather than typed into
    /// the copy, so the sentence cannot drift from where Grux actually looks.
    func testTheNamedFoldersAreTheOnesGruxReallyScans() {
        let copy = ProjectsView.emptyCopy(registryMissing: false)
        let realRoots = ProjectsIndex.scanRoots.map { ($0 as NSString).lastPathComponent }

        XCTAssertFalse(realRoots.isEmpty, "control: scanRoots is empty, so this test proves nothing")
        for root in realRoots {
            XCTAssertTrue(copy.body.contains("~/" + root),
                          "Grux scans ~/\(root) and the copy does not mention it")
        }
    }

    /// A missing optional capability is described as optional, not as a failure.
    /// The setup contract says the same thing in stronger words: a missing
    /// capability must never surface as an error.
    func testTheRegistryIsDescribedAsOptionalRatherThanBroken() {
        let withRegistry = ProjectsView.emptyCopy(registryMissing: false)
        XCTAssertNil(withRegistry.note,
                     "with a registry present there is nothing to explain about not having one")

        let without = ProjectsView.emptyCopy(registryMissing: true)
        let note = try? XCTUnwrap(without.note)
        XCTAssertTrue((note ?? "").lowercased().contains("nothing here is broken"),
                      "the absence of an optional component has to be stated as normal, or it reads as a fault")
    }

    // MARK: - Task Stack

    /// THE BUG. `groupMode` defaults to `.project` and `projectSections`
    /// iterates buckets derived from EXISTING tasks, so a user with none got
    /// zero sections and a completely blank list. The priority mode degrades
    /// fine, since it walks the fixed set of priorities, but that is not the
    /// mode anybody lands in.
    ///
    /// The add row above the list meant nobody was stranded, which is why this
    /// survived unnoticed. What was missing is the half that matters: nothing
    /// said the assistant fills this for you, which is the whole point of the
    /// surface.
    func testTheTaskStackSaysSomethingWhenItIsEmpty() {
        let copy = TasksDetailView.emptyCopy(assistantName: "Grux")
        XCTAssertFalse(copy.isEmpty)
        XCTAssertTrue(copy.lowercased().contains("add one above"),
                      "the manual control is right there and the copy should point at it")
        XCTAssertTrue(copy.lowercased().contains("chat"),
                      "the assistant filling this for you is the point of the surface")
    }

    /// It names a concrete phrase rather than saying "ask in chat". The tool
    /// that adds a task fires on wording like "remind me to", so an instruction
    /// whose shape the user has to guess is one they get wrong once and then
    /// stop trying.
    func testTheTaskStackCopyShowsTheActualPhrasingThatWorks() {
        let copy = TasksDetailView.emptyCopy(assistantName: "Grux")
        XCTAssertTrue(copy.lowercased().contains("remind me to"),
                      "the add_task tool fires on this wording, so the example has to use it")
    }

    /// And it follows the assistant's name like everything else.
    func testTheTaskStackCopyFollowsTheAssistantsName() {
        XCTAssertTrue(TasksDetailView.emptyCopy(assistantName: "Ada").contains("Ada"))
        XCTAssertFalse(TasksDetailView.emptyCopy(assistantName: "Ada").contains("Grux"))
    }

    // MARK: - Why there is NO general "ports in copy" test here
    //
    // One was written and deleted in the same pass, which is worth recording so
    // nobody writes it again.
    //
    // Two real defects prompted it: Media Studio said "The image service on
    // :3847 did not return an image", and the Meta Ads SUBTITLE, the first thing
    // anybody saw before the engine ever ran, was "port 3857 · OBSERVE". Both are
    // fixed, and both now carry a comment at the site saying why.
    //
    // The generalised rule does not survive contact with the tree. It flagged
    // four more, and every one was CORRECT:
    //
    //   SettingsView:808  is a TextField PLACEHOLDER showing the URL shape to
    //                     type, which is the most useful thing it could say.
    //   SettingsView:1209 names port 3852 while explaining that turning the
    //                     setting on OPENS A NETWORK LISTENER. Somebody deciding
    //                     that needs the port. Hiding it would be worse.
    //   SocialOpsService  is a default base URL constant, not copy at all.
    //
    // So the principle is not "never name a port". It is "do not explain
    // plumbing to somebody who cannot act on it", and whether a reader can act
    // on a given port is a judgement no regex makes. A test that fails on
    // correct code gets muted within a month and is worse than none, which is
    // the same conclusion OffByDefaultDiscoverabilityTests reached about
    // grepping for a Settings writer.
}
