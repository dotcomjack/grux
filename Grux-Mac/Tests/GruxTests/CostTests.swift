import XCTest
@testable import Grux
import GruxSetupCore

/// THE ONLY PROMISE THE PRODUCT MAKES ABOUT SETUP, AS ARITHMETIC.
///
/// gruxai.com says a permission is requested because a feature you picked needs it, and for
/// no other reason. That is either true of a given selection or it is not. These are the
/// same assertions the reviewed prototype holds, moved into Swift so the shipped binary is
/// held to them rather than the mockup.
///
/// Driven against the document the APP writes, not a synthetic fixture, so a change to the
/// registry that breaks the arithmetic fails here rather than in somebody's terminal.
@MainActor
final class CostTests: XCTestCase {

    private func liveStatus() throws -> SetupStatus {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-cost-\(UUID().uuidString)")
            .appendingPathComponent("setup-status.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(SetupStatusFile.write(to: url), "the app's writer failed")
        switch SetupStatusReader.read(from: url) {
        case .success(let s): return s
        case .failure(let e): throw XCTSkip("could not read what the app wrote: \(e)")
        }
    }

    private func cost(_ ids: [String], _ status: SetupStatus) -> GruxSetupCore.Cost {
        let byID = Dictionary(uniqueKeysWithValues: status.features.map { ($0.id, $0) })
        return .of(features: ids.compactMap { byID[$0] },
                   allCapabilities: status.capabilities.map(\.id),
                   allFeatures: status.features)
    }

    /// The website's sentence.
    func testPickNothingAndItAsksForNothing() throws {
        let status = try liveStatus()
        let bill = cost([], status)
        XCTAssertTrue(bill.blocking.isEmpty)
        XCTAssertTrue(bill.degrading.isEmpty)
        XCTAssertTrue(bill.choices.isEmpty)
        XCTAssertEqual(bill.never.count, status.capabilities.count,
                       "picking nothing must leave every capability on the never-asked list")
    }

    /// One feature costs exactly its own declaration and not a byte more.
    func testEveryFeatureAloneCostsExactlyItsOwnDeclaration() throws {
        let status = try liveStatus()
        var wrong: [String] = []
        for f in status.features {
            let bill = cost([f.id], status)
            let own = Set(f.requires + f.optional + f.steps + f.optionalSteps)
            let asked = Set(bill.touched)
            if asked != own { wrong.append(f.id) }
        }
        XCTAssertTrue(wrong.isEmpty,
            "\(wrong) cost something other than what they declare, checked across all "
            + "\(status.features.count) features")
    }

    /// Asked-for and never-asked-for must partition the contract, with no overlap and
    /// nothing missing. This is the trust claim, and a gap in it is a capability that is
    /// neither promised nor excluded.
    func testAskedForAndNeverPartitionTheContractExactly() throws {
        let status = try liveStatus()
        let total = status.capabilities.count
        for f in status.features {
            let bill = cost([f.id], status)
            let touched = Set(bill.touched)
            XCTAssertEqual(touched.count + bill.never.count, total,
                           "\(f.id): \(touched.count) + \(bill.never.count) != \(total)")
            XCTAssertTrue(touched.isDisjoint(with: Set(bill.never)),
                          "\(f.id) has a capability on both sides")
        }
    }

    /// A capability required by one feature must not be reported optional because another
    /// treats it that way. Somebody would skip it and land in a broken tab.
    func testRequiredBeatsOptionalAcrossFeatures() throws {
        let status = try liveStatus()
        let bill = cost(status.features.map(\.id), status)
        XCTAssertTrue(Set(bill.blocking).isDisjoint(with: Set(bill.degrading)),
                      "blocking and degrading overlap on the full selection")
    }

    /// THE OVER-ASKING GUARD. `chat` declares two credentials in `requires` with a group of
    /// min 1, so reading `requires` alone would demand both for a feature that needs one.
    func testNothingInsideAnAnyOfGroupIsReportedAsIndividuallyRequired() throws {
        let status = try liveStatus()
        var offenders: [String] = []
        for f in status.features {
            let bill = cost([f.id], status)
            for g in bill.choices {
                for cap in g.capabilities where bill.blocking.contains(cap) {
                    offenders.append("\(f.id)/\(cap)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "\(offenders) would be asked for twice over")
    }

    /// The specific case that made any-of necessary, named so a regression says which.
    func testChatAsksForOneCredentialNotTwo() throws {
        let status = try liveStatus()
        let bill = cost(["chat"], status)
        XCTAssertTrue(bill.blocking.isEmpty,
            "chat reported \(bill.blocking) as individually required. It needs an Anthropic "
            + "key OR a local model, and demanding both is exactly the over-asking the "
            + "any-of group exists to stop.")
        XCTAssertEqual(bill.choices.count, 1)
        XCTAssertEqual(bill.choices.first?.min, 1)
        XCTAssertEqual(Set(bill.choices.first?.capabilities ?? []),
                       ["key.anthropic", "endpoint.ollama"])
    }

    /// CR-35: a feature can be unusable because another feature is off, and no capability
    /// says so. The bill has to surface that or a selection can be priced as fine and still
    /// not do what was asked.
    func testAnUnmetFeatureDependencyIsReported() throws {
        let status = try liveStatus()
        let alone = cost(["speakers"], status)
        XCTAssertEqual(alone.unmetDependencies.map(\.feature), ["speakers"],
                       "Speakers without Meetings priced as fine")
        XCTAssertEqual(alone.unmetDependencies.first?.needs, ["Meetings"],
                       "the dependency is reported by id rather than by name")

        let together = cost(["speakers", "meetings"], status)
        XCTAssertTrue(together.unmetDependencies.isEmpty,
                      "a satisfied dependency is still being reported")
    }

    /// The whole selection must never leave a capability unaccounted for, which is the same
    /// sweep that found the ten unclaimed ids and turned out to be eight blueprint-claimed
    /// plus two real ones.
    func testTheFullSelectionAccountsForEveryCapabilityItCanUse() throws {
        let status = try liveStatus()
        let bill = cost(status.features.map(\.id), status)
        let touched = Set(bill.touched)
        for f in status.features {
            for id in f.requires + f.optional + f.steps + f.optionalSteps {
                XCTAssertTrue(touched.contains(id),
                              "\(id) is declared by \(f.id) and is not in the full bill")
            }
        }
    }
}
