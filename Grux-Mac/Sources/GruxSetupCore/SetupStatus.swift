import Foundation

/// The setup document, defined once and read by two programs.
///
/// ## Why the CLI does not carry a copy of the contract
///
/// The obvious shape for a setup CLI is to link the capability vocabulary and the feature
/// registry, so it can compute what is needed. That would put a second copy of a 41 id
/// contract and 39 feature rows in the tree, and the two would drift the first time somebody
/// edited one and shipped.
///
/// It is also unnecessary. `setup-status.json` already carries every id with its label, its
/// remediation, whether it is satisfied and whether anybody actually measured it, plus every
/// feature with its state, what is still blocking it, and what it depends on. The app is the
/// only thing that can compute those, because it is the only thing that can read the
/// Keychain under its own signature and ask macOS about a permission. So the CLI reads.
///
/// What it does NOT read from the file is a permission, because those go stale: somebody can
/// revoke Screen Recording in System Settings while the app is closed. `LivePermissions`
/// probes those directly, which is the one place the CLI measures rather than reads.
///
/// This type lives here so the writer and the reader cannot disagree about the shape.
public struct SetupStatus: Codable, Equatable, Sendable {

    /// A reader must refuse a document it does not understand rather than guess at a shape
    /// that changed under it.
    public static let supportedSchema = 3

    public var schema: Int
    public var generatedAt: String
    public var appVersion: String
    public var capabilities: [Capability]
    public var features: [Feature]
    public var summary: Summary

    public init(schema: Int, generatedAt: String, appVersion: String,
                capabilities: [Capability], features: [Feature], summary: Summary) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.capabilities = capabilities
        self.features = features
        self.summary = summary
    }

    public struct Capability: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var label: String
        public var satisfied: Bool
        /// True means nobody measured anything. Four consent decisions and two settings the
        /// app owns. No VERIFY section may imply a check that never ran.
        public var selfAttested: Bool
        /// Present only when unsatisfied.
        public var remediation: String?

        public init(id: String, kind: String, label: String, satisfied: Bool,
                    selfAttested: Bool, remediation: String?) {
            self.id = id
            self.kind = kind
            self.label = label
            self.satisfied = satisfied
            self.selfAttested = selfAttested
            self.remediation = remediation
        }
    }

    public struct Feature: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var tier: String
        public var state: String
        /// False only when the owner explicitly left this feature out. CR-36.
        public var chosen: Bool
        /// What is unmet RIGHT NOW, honouring any-of groups.
        public var missing: [String]
        /// The full declaration, so a selection can be priced before it is made. "What is
        /// wrong now" and "what would this cost" are different questions and the second
        /// cannot be answered from the first.
        public var requires: [String]
        public var optional: [String]
        public var steps: [String]
        public var optionalSteps: [String]
        public var anyOf: [Group]
        public var dependsOn: [String]

        public struct Group: Codable, Equatable, Sendable {
            public var capabilities: [String]
            public var min: Int
            public init(capabilities: [String], min: Int) {
                self.capabilities = capabilities
                self.min = min
            }
        }

        public init(id: String, label: String, tier: String, state: String,
                    chosen: Bool = true,
                    missing: [String], requires: [String], optional: [String],
                    steps: [String], optionalSteps: [String], anyOf: [Group],
                    dependsOn: [String]) {
            self.id = id
            self.label = label
            self.tier = tier
            self.state = state
            self.chosen = chosen
            self.missing = missing
            self.requires = requires
            self.optional = optional
            self.steps = steps
            self.optionalSteps = optionalSteps
            self.anyOf = anyOf
            self.dependsOn = dependsOn
        }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var capabilities: Int
        public var satisfied: Int
        public var selfAttested: Int
        public var featuresReady: Int
        public var featuresNeedingSetup: Int
        public var featuresChosen: Int

        public init(capabilities: Int, satisfied: Int, selfAttested: Int,
                    featuresReady: Int, featuresNeedingSetup: Int, featuresChosen: Int) {
            self.capabilities = capabilities
            self.satisfied = satisfied
            self.selfAttested = selfAttested
            self.featuresReady = featuresReady
            self.featuresNeedingSetup = featuresNeedingSetup
            self.featuresChosen = featuresChosen
        }
    }
}

// MARK: - Reading

/// Why the CLI could not answer, in the reader's terms rather than the filesystem's.
///
/// Each of these is a DESIGNED STATE with its own screen, not an error to print raw. "Grux
/// has never run" and "your Grux is newer than this binary" need different things from a
/// person, and collapsing them into "could not read file" is how a CLI becomes something you
/// have to already understand.
public enum SetupStatusReadError: Error, Equatable, Sendable {
    /// The app has never written it. Almost always means Grux has never been launched.
    case neverWritten(path: String)
    /// Present but not parseable. A truncated write should be impossible (the writer is
    /// atomic) so this means something else edited it.
    case unreadable(path: String)
    /// Written by a Grux that speaks a schema this binary does not.
    case unsupportedSchema(found: Int, supported: Int)
}

public enum SetupStatusReader {

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/setup-status.json")
    }

    public static func read(from url: URL = defaultURL) -> Result<SetupStatus, SetupStatusReadError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.neverWritten(path: url.path))
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SetupStatus.self, from: data) else {
            return .failure(.unreadable(path: url.path))
        }
        guard decoded.schema == SetupStatus.supportedSchema else {
            return .failure(.unsupportedSchema(found: decoded.schema,
                                               supported: SetupStatus.supportedSchema))
        }
        return .success(decoded)
    }

    /// How old the answer is, or nil when the timestamp will not parse.
    ///
    /// Staleness is a real question for a document written by another process. A person
    /// asking "what does Grux still need" after installing something wants to know whether
    /// they are reading an answer from before they installed it.
    public static func age(of status: SetupStatus, now: Date = Date()) -> TimeInterval? {
        guard let then = ISO8601DateFormatter().date(from: status.generatedAt) else { return nil }
        return now.timeIntervalSince(then)
    }
}
