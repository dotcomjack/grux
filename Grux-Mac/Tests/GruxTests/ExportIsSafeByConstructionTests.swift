import XCTest
@testable import GruxSetupCore

/// `grux export` cannot leak a credential, and this is why.
///
/// The distinction that matters is between REDACTING and never holding. A redacting exporter
/// reads secrets and promises to drop them, which is a promise somebody has to keep on every
/// field added afterwards, forever, in review. This exporter cannot leak one because the
/// document it reads has no credential in it: `setup-status.json` records that
/// `key.anthropic` is SATISFIED and nowhere records what it is.
///
/// So the check is not "did we redact". It is "can the source hold a value at all", and the
/// day somebody adds a field that could, this fails rather than the export quietly growing.
final class ExportIsSafeByConstructionTests: XCTestCase {

    /// Every field a capability HAS, not every field it happens to encode.
    ///
    /// REFLECTION, NOT ENCODING, and the difference is the whole test. The first version
    /// encoded a sample and compared the resulting keys, which passed against a planted
    /// `value: String?` because `JSONEncoder` omits a nil optional. An optional is exactly
    /// the shape a new credential field would take, and nil is exactly its state in a
    /// synthetic sample, so the check was blind in precisely the case it existed for.
    /// `Mirror` sees a stored property whether or not it has anything in it.
    func testACapabilityCanOnlyCarryStatesNeverValues() throws {
        let sample = SetupStatus.Capability(
            id: "key.anthropic", kind: "key", label: "Anthropic API key",
            satisfied: true, selfAttested: false, remediation: "Paste it in Settings.")

        let fields = Set(Mirror(reflecting: sample).children.compactMap(\.label))
        XCTAssertFalse(fields.isEmpty, "reflection found no fields, so this proves nothing")

        let allowed: Set<String> = ["id", "kind", "label", "satisfied", "selfAttested",
                                    "remediation"]
        let unexpected = fields.subtracting(allowed)

        XCTAssertTrue(unexpected.isEmpty,
            "a capability now carries \(unexpected.sorted().joined(separator: ", ")). "
            + "If any of those can hold a credential, `grux export` stopped being safe by "
            + "construction the moment it was added. Decide deliberately whether it may "
            + "leave the machine, then add it to the allowlist here.")
    }

    /// The same guarantee for a FEATURE, which the export also carries.
    func testAFeatureCanOnlyCarryStatesNeverValues() throws {
        let sample = SetupStatus.Feature(
            id: "chat", label: "Chat", tier: "core", state: "ready", chosen: true,
            missing: [], requires: [], optional: [], steps: [], optionalSteps: [],
            anyOf: [], dependsOn: [])
        let fields = Set(Mirror(reflecting: sample).children.compactMap(\.label))
        XCTAssertFalse(fields.isEmpty, "reflection found no fields")

        let allowed: Set<String> = ["id", "label", "tier", "state", "chosen", "missing",
                                    "requires", "optional", "steps", "optionalSteps",
                                    "anyOf", "dependsOn"]
        XCTAssertTrue(fields.subtracting(allowed).isEmpty,
            "a feature now carries "
            + "\(fields.subtracting(allowed).sorted().joined(separator: ", "))")
    }

    /// AND THE TYPES BACK IT UP. `satisfied` and `selfAttested` are booleans, so they cannot
    /// hold a token whatever they are named. The three strings are an id, a kind and copy
    /// written by us, none of which is read from a credential store.
    func testTheStateFieldsAreBooleansNotStrings() throws {
        let sample = SetupStatus.Capability(
            id: "key.anthropic", kind: "key", label: "Anthropic API key",
            satisfied: true, selfAttested: false, remediation: nil)
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sample)) as? [String: Any]

        XCTAssertTrue(object?["satisfied"] is Bool,
            "satisfied is no longer a boolean, so it can hold something other than a state")
        XCTAssertTrue(object?["selfAttested"] is Bool,
            "selfAttested is no longer a boolean")
    }

    /// The exporter names its fields one at a time rather than copying an object across.
    ///
    /// A wholesale encode would carry a new field out of the machine the day it was added,
    /// silently. Naming them means a new field has to be added HERE too, by somebody who has
    /// looked at it.
    func testTheExporterCopiesFieldsByNameRatherThanWholesale() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI/Commands/Export.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("\"id\": cap.id"),
            "the exporter no longer names its capability fields individually")
        XCTAssertFalse(source.contains("JSONEncoder().encode(status)"),
            "the exporter encodes the whole status document, so any field added to it "
            + "leaves the machine without anybody deciding that it should")
        XCTAssertFalse(source.contains("cap.remediation"),
            "the export carries remediation copy, which is bulk with no use on another Mac")
    }
}
