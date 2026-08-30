import Foundation
import Combine
import GruxAgentCore

// Activity strip model (blueprint section 03). Folds live swarm jobs from
// AgentService and the Foundry governor's cycle phase into a slim row of
// phase dots plus an estimated-cost ticker. Pure fold logic lives in
// ActivityStripFold so it unit-tests without touching the singletons.

// MARK: - Dot value

struct ActivityDot: Identifiable, Equatable {
    enum Kind: Equatable { case swarm, foundry }

    // Display phase, folded down from AgentJob.Status. `waiting` covers both
    // .waiting and .paused (amber "needs attention / parked" reads the same
    // at 7pt).
    enum Phase: String, Equatable {
        case queued
        case running
        case waiting
        case done
        case failed
        case cancelled
    }

    let id: String
    let title: String
    let phase: Phase
    let kind: Kind
    let estimatedUSD: Double

    // Hover tooltip copy.
    var tooltip: String { "\(title) | \(phase.rawValue)" }
}

// MARK: - Pure fold logic (unit tested)

enum ActivityStripFold {

    // Terminal jobs linger as done/failed dots for this long after they
    // complete, then drop off so the strip can auto-hide.
    static let lingerSeconds: TimeInterval = 300

    // Keep the strip slim: at most this many dots render. AgentService
    // publishes newest-first, so the cap keeps the most recent jobs.
    static let maxDots = 16

    static func phase(for status: AgentJob.Status) -> ActivityDot.Phase {
        switch status {
        case .queued: return .queued
        case .running: return .running
        case .waiting, .paused: return .waiting
        case .done: return .done
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    // Jobs -> dots. Non-terminal jobs always show; terminal jobs show only
    // while inside the linger window (completedAt within `linger` of `now`).
    // Terminal jobs without a completedAt are treated as stale and dropped.
    static func dots(
        jobs: [AgentJob],
        now: Date = Date(),
        linger: TimeInterval = lingerSeconds
    ) -> [ActivityDot] {
        jobs.compactMap { job -> ActivityDot? in
            if job.isTerminal {
                guard let completed = job.completedAt,
                      now.timeIntervalSince(completed) < linger else { return nil }
            }
            return ActivityDot(
                id: job.id,
                title: job.title,
                phase: phase(for: job.status),
                kind: .swarm,
                estimatedUSD: job.spentUSD
            )
        }
        .prefix(maxDots)
        .map { $0 }
    }

    // Estimated-cost ticker: the sum of non-terminal jobs' token-spend
    // estimates, plus the Foundry's current cycle budget estimate when the
    // governor is mid-pass. Terminal jobs drop out of the ticker immediately
    // (their dot lingers, their cost does not keep counting against "live").
    static func estimatedCostUSD(jobs: [AgentJob], foundryBudgetUSD: Double? = nil) -> Double {
        let swarm = jobs.filter { !$0.isTerminal }.reduce(0) { $0 + $1.spentUSD }
        return swarm + (foundryBudgetUSD ?? 0)
    }

    // Compact "$N estimated" label. Same rounding shape as
    // FoundryFormat.estimatedCostLabel ($N at or above 10 or whole dollars,
    // $N.NN below) but without the "(subscription powered)" tail, which does
    // not fit a 28pt strip. Returns nil at zero so the ticker hides.
    static func costLabel(usd: Double) -> String? {
        let clamped = max(0, usd)
        guard clamped > 0 else { return nil }
        let amount: String
        if clamped >= 10 {
            amount = "$\(Int(clamped.rounded()))"
        } else if clamped == clamped.rounded() {
            amount = "$\(Int(clamped))"
        } else {
            amount = String(format: "$%.2f", clamped)
        }
        return "\(amount) estimated"
    }

    // Earliest moment a lingering terminal dot expires, or nil when no
    // terminal dots are on screen. The model sleeps until this date and
    // refolds so done/failed dots actually fall off.
    static func nextExpiry(
        jobs: [AgentJob],
        now: Date = Date(),
        linger: TimeInterval = lingerSeconds
    ) -> Date? {
        jobs.compactMap { job -> Date? in
            guard job.isTerminal, let completed = job.completedAt else { return nil }
            let expiry = completed.addingTimeInterval(linger)
            return expiry > now ? expiry : nil
        }
        .min()
    }
}

// MARK: - Live model

@MainActor
final class ActivityStripModel: ObservableObject {

    static let shared = ActivityStripModel()

    @Published private(set) var dots: [ActivityDot] = []
    @Published private(set) var foundryPass: FoundryCyclePass?
    @Published private(set) var estimatedCostUSD: Double = 0

    // Strip renders only while something is alive: any dot (running or
    // lingering terminal) or a Foundry pass in flight.
    var isVisible: Bool { !dots.isEmpty || foundryPass != nil }

    var costLabel: String? { ActivityStripFold.costLabel(usd: estimatedCostUSD) }

    var runningCount: Int { dots.filter { $0.phase == .running }.count }

    // Test seam.
    var now: () -> Date = { Date() }

    private var latestJobs: [AgentJob] = []
    private var foundryBudgetUSD: Double?
    private var cancellables = Set<AnyCancellable>()
    private var expiryTask: Task<Void, Never>?

    private init() {
        AgentService.shared.$jobs
            .sink { [weak self] jobs in
                self?.latestJobs = jobs
                self?.refold()
            }
            .store(in: &cancellables)

        FoundryGovernor.shared.$phase
            .sink { [weak self] phase in
                if case .running(let pass) = phase {
                    self?.foundryPass = pass
                } else {
                    self?.foundryPass = nil
                }
                self?.refold()
            }
            .store(in: &cancellables)

        FoundryGovernor.shared.$currentBudget
            .sink { [weak self] budget in
                self?.foundryBudgetUSD = budget?.estimatedUSD
                self?.refold()
            }
            .store(in: &cancellables)
    }

    private func refold() {
        let nowDate = now()
        dots = ActivityStripFold.dots(jobs: latestJobs, now: nowDate)
        estimatedCostUSD = ActivityStripFold.estimatedCostUSD(
            jobs: latestJobs,
            foundryBudgetUSD: foundryPass != nil ? foundryBudgetUSD : nil
        )
        scheduleExpiry(from: nowDate)
        // Mirror to the paired phone (debounced, digest-gated, wire v2).
        SurfaceSyncEngine.shared.notifyActivityChanged()
    }

    // Sleep until the earliest lingering terminal dot expires, then refold
    // so the strip sheds done/failed dots and can collapse.
    private func scheduleExpiry(from nowDate: Date) {
        expiryTask?.cancel()
        guard let expiry = ActivityStripFold.nextExpiry(jobs: latestJobs, now: nowDate) else {
            expiryTask = nil
            return
        }
        let delay = max(0.1, expiry.timeIntervalSince(nowDate) + 0.1)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refold()
        }
    }

    // MARK: Phone mirror snapshot

    func activitySnapshotDTO() -> ActivitySnapshotDTO {
        ActivitySnapshotDTO(
            generatedAt: now(),
            jobs: dots.map { dot in
                ActivityJobDTO(
                    id: dot.id,
                    title: dot.title,
                    phase: dot.phase.rawValue,
                    isFoundry: dot.kind == .foundry,
                    estimatedUSD: dot.estimatedUSD
                )
            },
            foundryPass: foundryPass?.rawValue,
            estimatedCostLabel: costLabel ?? ""
        )
    }
}
