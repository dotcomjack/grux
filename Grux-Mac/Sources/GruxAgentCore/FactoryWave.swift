import Foundation

public struct WaveCandidate: Sendable, Equatable {
    public var name: String
    public var diff: String

    public init(name: String, diff: String) {
        self.name = name
        self.diff = diff
    }
}

public struct WaveResult: Sendable, Equatable {
    public var winner: String?
    public var scores: [String: Int32]
    public var refused: [String]

    public init(winner: String?, scores: [String: Int32], refused: [String]) {
        self.winner = winner
        self.scores = scores
        self.refused = refused
    }
}

/// Published Tier 3 pool for snapshot `daytona-small` (1 vCPU, 1 GiB, 3 GiB).
/// vCPU binds first: 250, before RAM (500) and disk (2,000 / 3 = 666).
/// Source: https://www.daytona.io/docs/en/limits fetched 2026-10-12.
/// The factory key got HTTP 401 on `GET /organizations`, so this is the
/// published pool, not a live quota read. The `$10,000` credit does not lower it.
public enum FactoryLimits {
    public static let tier3VCPU = 250
    public static let tier3MemoryGiB = 500
    public static let tier3StorageGiB = 2_000
    public static let smallVCPU = 1
    public static let smallMemoryGiB = 1
    public static let smallStorageGiB = 3
    public static let maxParallel = min(
        tier3VCPU / smallVCPU,
        tier3MemoryGiB / smallMemoryGiB,
        tier3StorageGiB / smallStorageGiB
    )
    /// Wallet recorded 2026-10-11. A wave stops only when spend is 0.
    public static let creditUSD = 10_000.0
}

public struct FactoryWave {
    public var maxParallel: Int
    public var spendUSD: Double

    public init(maxParallel: Int = FactoryLimits.maxParallel, spendUSD: Double = FactoryLimits.creditUSD) {
        self.maxParallel = min(FactoryLimits.maxParallel, max(1, maxParallel))
        self.spendUSD = spendUSD
    }

    /// Scores in input order. A task group would race a transport that hands
    /// scripted exits out in call order, so the exit would not stay bound to
    /// the candidate that owns it. The cap is applied before any create.
    public func run(_ candidates: [WaveCandidate], factory: DaytonaFactory) async -> WaveResult {
        _ = try? await factory.reap(olderThan: 1200)
        if spendUSD <= 0 {
            return WaveResult(
                winner: nil,
                scores: [:],
                refused: candidates.map { "\($0.name) spend-stop" }
            )
        }

        let scoreCommand = "bash factory/score.sh"
        var allowed: [WaveCandidate] = []
        var refused: [String] = []
        for candidate in candidates {
            if allowed.count >= maxParallel {
                refused.append("\(candidate.name) cap")
                continue
            }
            let verdict = FactoryPrivacy.check(diff: candidate.diff, scoreCommand: scoreCommand, env: [:])
            if case .refuse(let reason) = verdict {
                refused.append("\(candidate.name) \(reason)")
                continue
            }
            allowed.append(candidate)
        }

        var scores: [String: Int32] = [:]
        for candidate in allowed {
            let job = FactoryJob(diff: candidate.diff, scoreCommand: scoreCommand, timeoutSec: 180)
            do {
                let scored = try await factory.score(job)
                scores[candidate.name] = scored.exitCode
            } catch {
                scores[candidate.name] = 1
            }
        }

        let winner = allowed.first { scores[$0.name] == 0 }?.name
        return WaveResult(winner: winner, scores: scores, refused: refused)
    }
}
