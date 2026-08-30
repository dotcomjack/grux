import Foundation
import GruxShellCore

// Bridge exposing the iOS-engineering tools as ClaudeTool schemas for Grux's
// ChatService. All execution lives in GruxShellCore.IOSDispatcher - this file
// is pure schema glue.

enum IOSTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "ios_doctor",
                description: "Run a preflight audit before scaffolding an iOS app. Checks Xcode, xcodebuild, xcodegen, simulator runtimes, and optionally the configured Apple Team ID. Returns a list of ✅/❌ lines. Call BEFORE ios_scaffold the first time in a conversation, or whenever a toolchain error surfaces.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "require_team_id": [
                            "type": "boolean",
                            "description": "Set true when you intend to install on a physical device (rare). Default false - simulator-only builds don't need signing."
                        ]
                    ]
                ]
            ),
            ClaudeTool(
                name: "ios_scaffold",
                description: "Generate a complete, compilable iOS SwiftUI app on disk and run xcodegen to emit the .xcodeproj. Drops in tested templates for any subset of {chat, voiceMemos, tasks, focusSummary}. Refuses to overwrite an existing project dir. Returns xcodeproj_path, scheme, bundle_id, and the next-step pointer to ios_build_verify.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "project_name": [
                            "type": "string",
                            "description": "Alphanumeric only (no spaces/dashes). e.g. 'ProjectoAI'."
                        ],
                        "root_dir": [
                            "type": "string",
                            "description": "Absolute path to the parent folder where <project_name>/ will be created. Must be inside a Grux-allowed root."
                        ],
                        "bundle_id": [
                            "type": "string",
                            "description": "Full reverse-DNS id, e.g. 'com.example.projecto'. If omitted, built from bundle_prefix + project_name lowercased."
                        ],
                        "bundle_prefix": [
                            "type": "string",
                            "description": "Used only when bundle_id is omitted. Defaults to the configured developer bundle prefix."
                        ],
                        "features": [
                            "type": "array",
                            "items": [
                                "type": "string",
                                "enum": ["chat", "voiceMemos", "tasks", "focusSummary"]
                            ],
                            "description": "Subset to include. Default is all four."
                        ],
                        "min_ios": [
                            "type": "string",
                            "description": "Minimum iOS version, e.g. '17.0'. Default '17.0'."
                        ],
                        "team_id": [
                            "type": "string",
                            "description": "Apple Dev Team ID. Usually omitted - pulled from config.developer.teamId if needed for device install."
                        ]
                    ],
                    "required": ["project_name", "root_dir"]
                ]
            ),
            ClaudeTool(
                name: "ios_build_verify",
                description: "Run `xcodebuild` against the Simulator SDK and return a structured report: success/fail, list of errors with file:line:column, warnings, and the .app path on success. This is the feedback loop - if errors > 0, read them, patch the offending files via FilesystemTool write/edit, then call ios_build_verify again. Keep looping until errors = 0. Do NOT declare the app done until this returns success.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "project_path": [
                            "type": "string",
                            "description": "Absolute path to the .xcodeproj (from ios_scaffold output)."
                        ],
                        "scheme": [
                            "type": "string",
                            "description": "Scheme name. For Grux-scaffolded projects this equals project_name."
                        ],
                        "destination": [
                            "type": "string",
                            "description": "xcodebuild -destination arg. Default 'generic/platform=iOS Simulator'."
                        ]
                    ],
                    "required": ["project_path", "scheme"]
                ]
            ),
            ClaudeTool(
                name: "ios_simulator_run",
                description: "Boot an iPhone simulator, install the built .app, launch by bundle ID, and save a screenshot to disk. Opens Simulator.app so the run is visible on screen. Call this AFTER ios_build_verify returns success. Returns device_id, pid, screenshot path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "app_path": [
                            "type": "string",
                            "description": "Path to the built .app (from ios_build_verify result)."
                        ],
                        "bundle_id": [
                            "type": "string",
                            "description": "Bundle ID to launch (same as passed to ios_scaffold)."
                        ],
                        "device_name": [
                            "type": "string",
                            "description": "Exact simctl device name. Default 'iPhone 16'. Falls back to any available iPhone if exact match not installed."
                        ],
                        "screenshot_dir": [
                            "type": "string",
                            "description": "Optional. Defaults to ~/Library/Application Support/Grux/ios-screenshots."
                        ]
                    ],
                    "required": ["app_path", "bundle_id"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        return await IOSDispatcher.dispatch(name: name, input: input)
    }
}
