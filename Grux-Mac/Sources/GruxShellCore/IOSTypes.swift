import Foundation

// MARK: - Shared iOS-tool types
//
// Lives in GruxShellCore so the scaffolder, build-verify, simulator, doctor,
// and the dispatcher can share one vocabulary. No UI dependency.

public enum IOSFeature: String, Codable, Sendable, CaseIterable {
    case chat                   // Anthropic-backed chat
    case voiceMemos             // AVAudioRecorder + SFSpeechRecognizer
    case tasks                  // SwiftData task list
    case focusSummary           // UNUserNotificationCenter daily summary

    public var label: String {
        switch self {
        case .chat: return "AI Chat"
        case .voiceMemos: return "Voice Memos"
        case .tasks: return "Smart Tasks"
        case .focusSummary: return "Daily Focus"
        }
    }

    // Info.plist usage descriptions required to avoid runtime crash on first
    // permission prompt. Returned as (key, value) pairs.
    public var infoPlistKeys: [(String, String)] {
        switch self {
        case .voiceMemos:
            return [
                ("NSMicrophoneUsageDescription", "Record voice memos for on-device transcription."),
                ("NSSpeechRecognitionUsageDescription", "Transcribe your voice memos into text.")
            ]
        case .focusSummary:
            return []  // UNUserNotificationCenter asks at runtime, no plist key
        default:
            return []
        }
    }
}

public struct IOSScaffoldRequest: Sendable {
    public let projectName: String       // "ProjectoAI"
    public let bundleId: String          // "com.example.projecto"
    public let rootDir: String           // where to write the project tree
    public let features: [IOSFeature]
    public let minIOS: String            // "17.0"
    public let teamId: String?           // Apple Dev Team ID, nil → Xcode-managed automatic

    public init(projectName: String, bundleId: String, rootDir: String,
                features: [IOSFeature], minIOS: String = "17.0", teamId: String? = nil) {
        self.projectName = projectName
        self.bundleId = bundleId
        self.rootDir = rootDir
        self.features = features
        self.minIOS = minIOS
        self.teamId = teamId
    }
}

public struct IOSScaffoldResult: Sendable {
    public let projectDir: String          // rootDir/projectName
    public let xcodeprojPath: String       // .../ProjectoAI.xcodeproj
    public let scheme: String              // ProjectoAI
    public let filesCreated: [String]      // relative paths written
    public let xcodegenOutput: String      // for logs / user messaging
}

public struct IOSBuildError: Codable, Sendable {
    public let file: String      // relative path or absolute
    public let line: Int?
    public let column: Int?
    public let message: String
    public let severity: String  // "error" or "warning"
}

public struct IOSBuildResult: Sendable {
    public let success: Bool
    public let exitCode: Int32
    public let appPath: String?              // Debug-iphonesimulator/<name>.app
    public let errors: [IOSBuildError]
    public let warnings: [IOSBuildError]
    public let durationSec: Double
    public let stdoutTail: String            // last ~2KB, for Claude to chew on
}

public struct IOSSimulatorResult: Sendable {
    public let deviceId: String
    public let deviceName: String
    public let bundleId: String
    public let installed: Bool
    public let launched: Bool
    public let pid: Int?
    public let screenshotPath: String?       // .png on disk
    public let log: String
}

public struct IOSDoctorReport: Sendable {
    public struct Check: Sendable {
        public let name: String
        public let ok: Bool
        public let detail: String
        public init(name: String, ok: Bool, detail: String) {
            self.name = name; self.ok = ok; self.detail = detail
        }
    }
    public let allOk: Bool
    public let checks: [Check]
}

public enum IOSToolError: Error, CustomStringConvertible {
    case xcodegenMissing
    case xcodeMissing(String)
    case invalidRootDir(String)
    case projectExists(String)
    case scaffoldFailed(String)
    case buildFailed(String)
    case simulatorFailed(String)
    case notSupported(String)

    public var description: String {
        switch self {
        case .xcodegenMissing: return "xcodegen is not installed (brew install xcodegen)"
        case .xcodeMissing(let m): return "Xcode toolchain problem: \(m)"
        case .invalidRootDir(let p): return "invalid root_dir: \(p)"
        case .projectExists(let p): return "project already exists at \(p) - refusing to overwrite"
        case .scaffoldFailed(let m): return "scaffold failed: \(m)"
        case .buildFailed(let m): return "build failed: \(m)"
        case .simulatorFailed(let m): return "simulator flow failed: \(m)"
        case .notSupported(let m): return "not supported: \(m)"
        }
    }
}
