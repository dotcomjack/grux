import Foundation

// MARK: - IOSProjectGen
//
// Generates a compilable iOS SwiftUI project on disk and runs xcodegen to emit
// the .xcodeproj. Layout:
//
//   <rootDir>/<ProjectName>/
//     project.yml
//     Info.plist
//     <ProjectName>.entitlements            (present but empty for now)
//     Sources/
//       <ProjectName>App.swift
//       ContentView.swift
//       Keychain.swift                      (if chat)
//       AnthropicClient.swift               (if chat)
//       ChatView.swift                      (if chat)
//       APIKeySheet.swift                   (if chat)
//       VoiceMemosView.swift                (if voiceMemos)
//       TasksView.swift                     (if tasks)
//       FocusView.swift + FocusScheduler.swift  (if focusSummary)
//     Resources/
//       LaunchScreen.storyboard
//       Assets.xcassets/
//         AppIcon.appiconset/Contents.json
//
// The scaffolder does NOT overwrite an existing project dir - bail with
// .projectExists so we never clobber in-progress work.

public enum IOSProjectGen {

    public static func scaffold(_ req: IOSScaffoldRequest) async throws -> IOSScaffoldResult {
        let fm = FileManager.default

        // Validate rootDir
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: req.rootDir, isDirectory: &isDir), isDir.boolValue else {
            throw IOSToolError.invalidRootDir(req.rootDir)
        }

        let projectDir = (req.rootDir as NSString).appendingPathComponent(req.projectName)
        if fm.fileExists(atPath: projectDir) {
            throw IOSToolError.projectExists(projectDir)
        }
        let sourcesDir = (projectDir as NSString).appendingPathComponent("Sources")
        let resourcesDir = (projectDir as NSString).appendingPathComponent("Resources")
        let assetsDir = (resourcesDir as NSString).appendingPathComponent("Assets.xcassets")
        let appIconDir = (assetsDir as NSString).appendingPathComponent("AppIcon.appiconset")

        try fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: appIconDir, withIntermediateDirectories: true)

        var written: [String] = []
        func write(_ rel: String, _ content: String) throws {
            let full = (projectDir as NSString).appendingPathComponent(rel)
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
            written.append(rel)
        }

        // 1. Source files
        try write("Sources/\(req.projectName)App.swift",
                  IOSTemplates.appEntry(projectName: req.projectName, features: req.features))
        try write("Sources/ContentView.swift",
                  IOSTemplates.contentView(features: req.features))
        if req.features.contains(.chat) {
            try write("Sources/Keychain.swift", IOSTemplates.keychain())
            try write("Sources/AnthropicClient.swift", IOSTemplates.anthropicClient())
            try write("Sources/ChatView.swift", IOSTemplates.chatView())
            try write("Sources/APIKeySheet.swift", IOSTemplates.apiKeySheet())
        }
        if req.features.contains(.voiceMemos) {
            try write("Sources/VoiceMemosView.swift", IOSTemplates.voiceMemosView())
        }
        if req.features.contains(.tasks) {
            try write("Sources/TasksView.swift", IOSTemplates.tasksView())
        }
        if req.features.contains(.focusSummary) {
            try write("Sources/FocusView.swift", IOSTemplates.focusView())
            try write("Sources/FocusScheduler.swift", IOSTemplates.focusScheduler())
        }

        // 2. Resources
        try write("Resources/LaunchScreen.storyboard",
                  IOSTemplates.launchScreenStoryboard(appName: req.projectName))
        try write("Resources/Assets.xcassets/Contents.json",
                  #"{"info":{"author":"xcode","version":1}}"#)
        try write("Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
                  // No actual PNG: we declare universal idiom with no image refs.
                  // xcodebuild for simulator emits a warning but succeeds.
                  emptyAppIconContentsJSON())

        // 3. Info.plist - merges per-feature keys
        try write("Info.plist", infoPlist(req: req))

        // 4. Entitlements - empty but valid; referenced in project.yml for
        // future-proofing (push, iCloud, etc.)
        try write("\(req.projectName).entitlements", emptyEntitlements())

        // 5. project.yml for xcodegen
        try write("project.yml", projectYML(req: req))

        // 6. README
        try write("README.md",
                  IOSTemplates.readme(projectName: req.projectName,
                                      bundleId: req.bundleId,
                                      features: req.features))

        // 7. Run xcodegen generate inside projectDir
        let xcodegenOut = try await runXcodegen(projectDir: projectDir)

        let xcodeprojPath = (projectDir as NSString).appendingPathComponent("\(req.projectName).xcodeproj")
        guard fm.fileExists(atPath: xcodeprojPath) else {
            throw IOSToolError.scaffoldFailed("xcodegen did not produce .xcodeproj - output: \(xcodegenOut)")
        }

        // 8. Drop a `.grux/project.json` marker so the Grux desktop app's
        // Projects tab can discover and enrich this scaffold (scheme, bundle,
        // last build, last screenshot). Non-fatal if write fails - the
        // scaffold itself already succeeded.
        let marker = LocalProjectMarker(
            projectName: req.projectName,
            rootDir: req.rootDir,
            bundleId: req.bundleId,
            scheme: req.projectName,
            xcodeprojPath: xcodeprojPath,
            features: req.features.map(\.rawValue)
        )
        try? marker.write()

        return IOSScaffoldResult(
            projectDir: projectDir,
            xcodeprojPath: xcodeprojPath,
            scheme: req.projectName,
            filesCreated: written,
            xcodegenOutput: xcodegenOut
        )
    }

    // MARK: - Helpers

    private static func emptyAppIconContentsJSON() -> String {
        """
        {
          "images" : [
            {
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
    }

    private static func emptyEntitlements() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        </dict>
        </plist>
        """
    }

    private static func infoPlist(req: IOSScaffoldRequest) -> String {
        // Start with the baseline iOS keys, append per-feature usage descriptions.
        var perFeaturePlist = ""
        for feature in req.features {
            for (key, value) in feature.infoPlistKeys {
                perFeaturePlist += """

                    <key>\(key)</key>
                    <string>\(xmlEscape(value))</string>
                """
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>$(DEVELOPMENT_LANGUAGE)</string>
            <key>CFBundleDisplayName</key>
            <string>\(req.projectName)</string>
            <key>CFBundleExecutable</key>
            <string>$(EXECUTABLE_NAME)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSRequiresIPhoneOS</key>
            <true/>
            <key>UIApplicationSceneManifest</key>
            <dict>
                <key>UIApplicationSupportsMultipleScenes</key>
                <true/>
            </dict>
            <key>UILaunchStoryboardName</key>
            <string>LaunchScreen</string>
            <key>UIRequiredDeviceCapabilities</key>
            <array>
                <string>arm64</string>
            </array>
            <key>UISupportedInterfaceOrientations</key>
            <array>
                <string>UIInterfaceOrientationPortrait</string>
                <string>UIInterfaceOrientationLandscapeLeft</string>
                <string>UIInterfaceOrientationLandscapeRight</string>
            </array>\(perFeaturePlist)
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func projectYML(req: IOSScaffoldRequest) -> String {
        let teamIdLine = req.teamId.map { "    DEVELOPMENT_TEAM: \($0)\n" } ?? ""
        return """
        name: \(req.projectName)
        options:
          deploymentTarget:
            iOS: "\(req.minIOS)"
          bundleIdPrefix: \((req.bundleId as NSString).deletingPathExtension)
          xcodeVersion: "16.0"
        settings:
          base:
            SWIFT_VERSION: 5.9
            IPHONEOS_DEPLOYMENT_TARGET: \(req.minIOS)
            MARKETING_VERSION: 1.0
            CURRENT_PROJECT_VERSION: 1
            TARGETED_DEVICE_FAMILY: "1,2"
            ENABLE_PREVIEWS: YES
        \(teamIdLine)targets:
          \(req.projectName):
            type: application
            platform: iOS
            sources:
              - Sources
              - path: Resources/LaunchScreen.storyboard
              - path: Resources/Assets.xcassets
            resources: []
            info:
              path: Info.plist
            entitlements:
              path: \(req.projectName).entitlements
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: \(req.bundleId)
                INFOPLIST_FILE: Info.plist
                CODE_SIGN_STYLE: Automatic
                CODE_SIGN_IDENTITY: "-"
                GENERATE_INFOPLIST_FILE: NO
        """
    }

    private static func runXcodegen(projectDir: String) async throws -> String {
        // Resolve xcodegen - check PATH entries one at a time so we bail cleanly
        // with a friendly error if it's missing.
        let candidates = [
            "/opt/homebrew/bin/xcodegen",
            "/usr/local/bin/xcodegen"
        ]
        let which = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let xcg = which else {
            throw IOSToolError.xcodegenMissing
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xcg)
        proc.arguments = ["generate", "--spec", "project.yml"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw IOSToolError.scaffoldFailed("xcodegen exit=\(proc.terminationStatus)\n\(err)\(out)")
        }
        return out + err
    }
}
