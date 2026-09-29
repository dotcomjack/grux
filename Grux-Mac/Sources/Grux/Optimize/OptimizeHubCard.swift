import SwiftUI
import AppKit
import Combine

/// Whether the Optimize hub card is expanded, which order it should show
/// first, and what the last door did. Shared so a Now row, the palette, a
/// trigger and first run can all open it.
@MainActor
final class OptimizeHubState: ObservableObject {
    static let shared = OptimizeHubState()
    /// Collapsing drops the last door's note and any unspent focus request.
    /// Expanding asks the proposals again, so a live check that turned true
    /// since the last open shows its Success card.
    @Published var isExpanded = false {
        didSet {
            guard !isExpanded else {
                if !oldValue { refreshCard() }
                return
            }
            note = nil
            focusPending = false
        }
    }
    @Published var highlightedOrder: String? = nil
    /// Set by the Change door, spent by the card once the request field has
    /// focus. One-shot, so a later expand (a review popping the card, a
    /// trigger, a theme remount) never pulls typing into the field.
    @Published private(set) var focusPending = false
    /// What the last door did, shown under the doors whether or not any work
    /// order exists. Cleared by the next door press and by collapsing.
    @Published var note: OptimizeNote? = nil
    /// The proposal up front when the card opens: Proposed until its change
    /// exists, then Success in the same place, until Got it. Kept live from
    /// the store, so it turns into Success while the card is on screen the
    /// moment its order writes `done`.
    @Published private(set) var card: ProposalCard?
    /// The proposal's button reads as copied for a moment after a press.
    @Published private(set) var proposalCopied = false
    private var copiedReset: Task<Void, Never>?
    private var lastReviews = 0
    /// Proposals set aside with Not now: this launch only, nothing on disk.
    private var setAside: Set<String> = []
    private let handOff: @MainActor () -> Result<URL, Swift.Error>
    private let proposals: () -> [OptimizeProposal]
    private let store: WorkOrderStore
    private var watching: AnyCancellable?

    /// `handOff`, `proposals` and `store` are for tests; the app writes the
    /// live bundle, offers the shipped proposals, and keeps its orders and
    /// acknowledgements in the shared store.
    init(handOff: @escaping @MainActor () -> Result<URL, Swift.Error> = { HandoffBundle.writeLive() },
         proposals: @autoclosure @escaping () -> [OptimizeProposal] = OptimizeProposals.shipped,
         store: WorkOrderStore? = nil) {
        self.handOff = handOff
        self.proposals = proposals
        let store = store ?? .shared
        self.store = store
        // @Published emits before the property changes, so the card is built
        // from the emitted values, not read back from the store.
        watching = store.$orders.combineLatest(store.$acknowledgedProposals, store.$seenProposals)
            .sink { [weak self] orders, acknowledged, seen in
                self?.refreshCard(orders: orders, acknowledged: acknowledged, seen: seen)
            }
    }

    private func refreshCard() {
        refreshCard(orders: store.orders, acknowledged: store.acknowledgedProposals, seen: store.seenProposals)
    }

    private func refreshCard(orders: [WorkOrderStore.Order], acknowledged: Set<String>, seen: Set<String>) {
        let next = OptimizeProposals.card(from: proposals(), orders: orders, acknowledged: acknowledged,
                                          seen: seen, setAside: setAside)
        if next != card { card = next }
        // A Proposed card on screen is evidence this install saw the work.
        // markSeen is a no-op once recorded, so the reload it triggers does
        // not come back through here a second time.
        if isExpanded, let next, case .proposed = next.state { store.markSeen(proposal: next.proposal.id) }
    }

    /// The proposal the card is about, Proposed or Success.
    var proposal: OptimizeProposal? { card?.proposal }

    /// The Proposed card sits above the doors only while the card is open.
    var showsProposal: Bool {
        guard isExpanded, case .proposed = card?.state else { return false }
        return true
    }

    /// The Success card takes the Proposed card's place.
    var showsSuccess: Bool { isExpanded && card?.state == .success }

    /// Where the proposal's order is on the line, once it has one.
    var proposalStation: WorkOrderStage? {
        if case .proposed(let station) = card?.state { return station }
        return nil
    }

    /// Not now: the doors move up, and the proposal stays away until relaunch.
    func dismissProposal() {
        if let id = card?.proposal.id { setAside.insert(id) }
        refreshCard()
        copiedReset?.cancel()
        proposalCopied = false
    }

    /// Got it: the Success card goes for good, across relaunches, and the
    /// next proposal (or none) takes its place.
    func acknowledgeSuccess() {
        guard let card, card.state == .success else { return }
        store.acknowledge(proposal: card.proposal.id)
        refreshCard()
    }

    /// Open the setting: the Settings row the proposal added.
    func openProposalSetting() {
        guard let tag = card?.proposal.settingsTag else { return }
        AppState.shared.requestedSettingsTab = tag
        open("settings")
    }

    /// Writes the proposal as a real work order through the one line, copies
    /// that order's text, and confirms on the button for `confirmFor`. The
    /// order then shows under the doors with its station, live, and the card
    /// turns into Success when it writes `done`. A second press while that
    /// order is still moving copies the same order again rather than
    /// starting a second agent on it.
    func copyProposal(copy: (String) -> Void = OptimizeClipboard.copy, confirmFor: Duration = .seconds(2.5)) {
        guard case .proposed? = card?.state, let proposal else { return }
        let order: WorkOrderStore.Order
        if let moving = store.orders.first(where: { $0.proposalId == proposal.id && !$0.progress.stage.isFinished }),
           let text = store.workOrderText(moving) ?? store.rewriteWorkOrder(moving, detail: proposal.detail) {
            copy(text)
            order = moving
        } else if let written = store.createAndCopy(proposal.request, detail: proposal.detail,
                                                     proposal: proposal.id, copy: copy) {
            order = written
        } else {
            return
        }
        note = .copied(orderId: order.id)
        proposalCopied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: confirmFor)
            guard !Task.isCancelled else { return }
            self?.proposalCopied = false
        }
    }

    /// A work order reaching a review pops the card open once per rise.
    func noteReviewsWaiting(_ n: Int) {
        if n > lastReviews { isExpanded = true }
        lastReviews = n
    }

    /// The card focused its request field.
    func consumeFocus() { focusPending = false }

    func enter(_ door: OptimizeDoor) {
        note = nil
        switch door {
        case .tune: open("tuning")
        case .change:
            isExpanded = true
            focusPending = true
        case .handOver:
            isExpanded = true
            switch handOff() {
            case .success(let url): note = .handedOver(url)
            case .failure(let error): note = .failed(OptimizeCopy.handoffFailed(error.localizedDescription))
            }
        case .improve: open("selfUpgrade")
        }
    }

    /// Opens a pane through the trigger contract, counted as the hub's open.
    /// The pane already open is left alone, so no door is left pending.
    private func open(_ key: String) {
        guard AppState.shared.requestedTab != key else { return }
        OpensLog.shared.nextVia = .hub
        AppState.shared.requestedTab = key
    }
}

/// The line under the doors.
enum OptimizeNote: Equatable {
    case copied(orderId: String)
    case handedOver(URL)
    case failed(String)
}

enum OptimizeDoor: String, CaseIterable, Identifiable {
    case tune, change, handOver, improve
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tune: return "Tune it"
        case .change: return "Change it"
        case .handOver: return "Hand it over"
        case .improve: return "Let it improve itself"
        }
    }
    var body: String {
        switch self {
        case .tune: return "How sure Grux must be, how often it interrupts, what it spends and remembers."
        case .change: return "Say what you want different. Grux writes a work order your coding agent builds."
        case .handOver: return "Export your settings, theme and macros as a bundle your agent can read and apply."
        case .improve: return "Grux proposes its own upgrades. You choose how far that goes."
        }
    }
    var icon: String {
        switch self {
        case .tune: return "slider.horizontal.3"
        case .change: return "wand.and.stars"
        case .handOver: return "shippingbox.fill"
        case .improve: return "hammer.fill"
        }
    }

    /// The door's live state line, if it has one. Improve shows the Foundry's
    /// pending proposals from the count `FoundryStatusBadge` shows, and like
    /// the badge it shows nothing at zero.
    func status(pendingProposals: Int) -> String? {
        guard self == .improve, pendingProposals > 0 else { return nil }
        return "\(pendingProposals) proposal\(pendingProposals == 1 ? "" : "s") waiting"
    }
}

extension OptimizeCopy {
    static let hubCaption = "Make it yours, then hand it to your agent."
    /// The Success card's eyebrow and its one button.
    static let success = "Done"
    static let gotIt = "Got it"
    static let openSetting = "Open the setting"
    /// Under the Proposed card once its order exists.
    static func proposalStation(_ stage: WorkOrderStage) -> String {
        stage == .written ? WorkOrderStage.written.title : "Your agent: \(stage.title)"
    }
    static let handoffWritten = "Bundle written. The setup prompt is on your clipboard."
    static let copyWorkOrder = "Copy work order"
    static let revealInFinder = "Reveal in Finder"
    /// Over the proposed action, so it reads as a suggestion, not a fact.
    static let proposed = "Proposed"
    static let proposalNotNow = "Not now"
    /// The one button, before and for a moment after the press. The spoken
    /// label uses the same words as the visible one.
    static func proposalButton(copied: Bool) -> String {
        copied ? "Copied. Paste it to your agent." : "Copy the fix for your agent"
    }
    static func handoffFailed(_ reason: String) -> String { "Could not write the bundle: \(reason)" }
    /// The bundle path as the note shows it: the home folder reads as ~.
    static func displayPath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// The card in the panel: collapsed to one row, or expanded to four doors
/// with the Change door's work-order field inline.
struct OptimizeHubCard: View {
    @ObservedObject private var hub: OptimizeHubState
    @ObservedObject private var store: WorkOrderStore
    // The same model FoundryStatusBadge reads, so the door and the head
    // badge cannot disagree.
    @ObservedObject private var foundry = FoundryDashboardModel.shared
    @State private var request = ""
    @FocusState private var requestFocused: Bool
    /// Screenshots staged for the next order, as PNG bytes.
    @State private var images: [Data] = []
    @State private var imageError: String?
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    /// The parameters are for tests; the panel passes none and gets the
    /// shared ones.
    @MainActor
    init(store: WorkOrderStore? = nil, hub: OptimizeHubState? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
        _hub = ObservedObject(wrappedValue: hub ?? .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Button { hub.isExpanded.toggle() } label: {
                HStack(spacing: GruxSpacing.s) {
                    Image(systemName: "wand.and.stars")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.accentPrimary)
                    Text(OptimizeCopy.title)
                        .font(GruxType.title)
                        .foregroundStyle(GruxTheme.textPrimary)
                    if store.waitingOnYou > 0 {
                        Circle().fill(GruxTheme.warnAmber)
                            .frame(width: GruxSpacing.s, height: GruxSpacing.s)
                            .accessibilityLabel("\(store.waitingOnYou) waiting on your review")
                    }
                    Spacer()
                    Image(systemName: hub.isExpanded ? "chevron.up" : "chevron.down")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(OptimizeCopy.title)

            if hub.isExpanded {
                Text(OptimizeCopy.hubCaption)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                if hub.showsProposal, let proposal = hub.proposal { proposalBlock(proposal) }
                if hub.showsSuccess, let proposal = hub.proposal { successBlock(proposal) }
                ForEach(OptimizeDoor.allCases) { door in
                    doorRow(door)
                    if door == .change { changeInline }
                }
                if let note = hub.note { noteLine(note) }
                if !store.orders.isEmpty { ordersList }
            }
        }
        .padding(GruxSpacing.l)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.card)
            .fill(GruxTheme.accentPrimary.opacity(0.08)))
        // Spec 3.2: expanded whenever an order waits at a review, including
        // one that was already waiting when the app launched.
        .onAppear { hub.noteReviewsWaiting(store.waitingOnYou) }
        .onChange(of: store.waitingOnYou) { _, n in hub.noteReviewsWaiting(n) }
        .task { await store.pollWhileActive() }
    }

    /// The proposed action, above the doors: an eyebrow, a headline, one
    /// line, one button, and Not now. Full width of the card, so nothing
    /// jumps when it goes.
    private func proposalBlock(_ proposal: OptimizeProposal) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text(OptimizeCopy.proposed)
                .font(GruxType.microCaps)
                .kerning(GruxType.microCapsTracking)
                .foregroundStyle(GruxTheme.accentPrimary)
            Text(proposal.headline)
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)
            Text(proposal.line)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let station = hub.proposalStation {
                Text(OptimizeCopy.proposalStation(station))
                    .font(GruxType.caption)
                    .foregroundStyle(station.isReview ? GruxTheme.warnAmber : GruxTheme.accentPrimary)
            }
            HStack(spacing: GruxSpacing.m) {
                Button { hub.copyProposal() } label: {
                    Text(OptimizeCopy.proposalButton(copied: hub.proposalCopied))
                        .font(GruxType.body)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(GruxTheme.accentPrimary)
                .accessibilityLabel(OptimizeCopy.proposalButton(copied: hub.proposalCopied))
                Button(OptimizeCopy.proposalNotNow) { hub.dismissProposal() }
                    .buttonStyle(.borderless)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .accessibilityLabel(OptimizeCopy.proposalNotNow)
            }
            .padding(.top, GruxSpacing.xs)
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
            .fill(GruxTheme.accentPrimary.opacity(0.12)))
    }

    /// The Success card, in the Proposed card's place and shape: an eyebrow,
    /// the result as a fact, where it lives, and Got it.
    private func successBlock(_ proposal: OptimizeProposal) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text(OptimizeCopy.success)
                .font(GruxType.microCaps)
                .kerning(GruxType.microCapsTracking)
                .foregroundStyle(GruxTheme.successMint)
            Text(proposal.successHeadline)
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)
            Text(proposal.successLine)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: GruxSpacing.m) {
                Button { hub.acknowledgeSuccess() } label: {
                    Text(OptimizeCopy.gotIt)
                        .font(GruxType.body)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .tint(GruxTheme.accentPrimary)
                .accessibilityLabel(OptimizeCopy.gotIt)
                if proposal.settingsTag != nil {
                    Button(OptimizeCopy.openSetting) { hub.openProposalSetting() }
                        .buttonStyle(.borderless)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .accessibilityLabel(OptimizeCopy.openSetting)
                }
            }
            .padding(.top, GruxSpacing.xs)
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
            .fill(GruxTheme.successMint.opacity(0.12)))
    }

    private func doorRow(_ door: OptimizeDoor) -> some View {
        Button { hub.enter(door) } label: {
            HStack(alignment: .top, spacing: GruxSpacing.s) {
                Image(systemName: door.icon)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.accentPrimary)
                    .frame(width: GruxSpacing.l)
                VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    Text(door.title)
                        .font(GruxType.body)
                        .foregroundStyle(GruxTheme.textPrimary)
                    Text(door.body)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status = door.status(pendingProposals: foundry.pendingCount) {
                        Text(status)
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.accentPrimary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(door.title)
    }

    private var changeInline: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            HStack(spacing: GruxSpacing.s) {
                TextField(OptimizeCopy.placeholder, text: $request)
                    .textFieldStyle(.plain)
                    .font(GruxType.body)
                    .focused($requestFocused)
                    .padding(.horizontal, GruxSpacing.m)
                    .padding(.vertical, GruxSpacing.s)
                    .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                        .fill(GruxTheme.chipFill))
                    .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                        .strokeBorder(GruxTheme.accentPrimary.opacity(dropTargeted ? 0.85 : 0)))
                    .onSubmit(copyNew)
                    .accessibilityLabel("What should Grux do differently")
                Button(OptimizeCopy.copyWorkOrder, action: copyNew)
                    .disabled(WorkOrderPrompt.clean(request) == nil)
            }
            if !images.isEmpty { thumbnails }
            if let imageError {
                Text(imageError)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.warnAmber)
            }
        }
        .padding(.leading, GruxSpacing.l + GruxSpacing.s)
        // A screenshot dropped anywhere on the box goes with the next order.
        .onDrop(of: ImageIngest.acceptedDropTypes, isTargeted: $dropTargeted) { providers in
            imageError = nil
            return ImageIngest.load(providers, all: true) { result in
                switch result {
                case .success(let image): stage(image)
                case .failure(let failure): imageError = failure.message
                }
            }
        }
        // The field appears when the Change door expands the card, and a
        // press on an open card flips the flag: either way, focus once.
        .onAppear {
            takeFocusIfAsked()
            installPasteMonitor()
        }
        .onDisappear(perform: removePasteMonitor)
        .onChange(of: hub.focusPending) { _, pending in if pending { takeFocusIfAsked() } }
    }

    private var thumbnails: some View {
        HStack(spacing: GruxSpacing.s) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: GruxLayout.attachmentThumb, height: GruxLayout.attachmentThumb)
                        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                images.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(GruxType.caption)
                                    .foregroundStyle(GruxTheme.textPrimary, GruxTheme.base)
                            }
                            .buttonStyle(.plain)
                            .help(OptimizeCopy.removeScreenshot)
                            .accessibilityLabel(OptimizeCopy.removeScreenshot)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(OptimizeCopy.screenshot(index + 1))
                }
            }
        }
    }

    private func stage(_ image: NSImage) {
        guard let png = ImageIngest.png(from: image) else {
            imageError = ImageIngest.cannotEncode
            return
        }
        images.append(png)
        imageError = nil
    }

    /// Command-V with an image on the clipboard, while the box has focus.
    /// The text field's editor takes paste before SwiftUI's onPasteCommand
    /// sees it, and it only pastes text, so the key is caught one level up.
    /// Text on the clipboard falls through to the field as before.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard requestFocused,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pasted = ImageIngest.images(on: .general)
            guard !pasted.isEmpty else { return event }
            pasted.forEach(stage)
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    private func takeFocusIfAsked() {
        guard hub.focusPending else { return }
        requestFocused = true
        hub.consumeFocus()
    }

    @ViewBuilder
    private func noteLine(_ note: OptimizeNote) -> some View {
        switch note {
        case .copied(let id):
            Text(OptimizeCopy.copied(id))
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.successMint)
        case .handedOver(let url):
            VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                Text(OptimizeCopy.handoffWritten)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.successMint)
                HStack(spacing: GruxSpacing.s) {
                    Text(OptimizeCopy.displayPath(url))
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(OptimizeCopy.revealInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.borderless)
                    .font(GruxType.caption)
                }
            }
        case .failed(let message):
            Text(message)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.warnAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ordersList: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Divider()
            ForEach(visibleOrders) { order in
                WorkOrderRow(order: order, store: store) { hub.note = .copied(orderId: order.id) }
                    .background(order.id == hub.highlightedOrder
                                ? RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                                    .fill(GruxTheme.warnAmber.opacity(0.10))
                                : nil)
            }
        }
    }

    /// The newest three, plus the order a Now row asked for if it is older.
    private var visibleOrders: [WorkOrderStore.Order] {
        var shown = Array(store.orders.prefix(3))
        if let id = hub.highlightedOrder, !shown.contains(where: { $0.id == id }),
           let order = store.orders.first(where: { $0.id == id }) {
            shown.append(order)
        }
        return shown
    }

    private func copyNew() {
        guard let order = store.createAndCopy(request, images: images) else { return }
        hub.note = .copied(orderId: order.id)
        request = ""
        images = []
        imageError = nil
    }
}
