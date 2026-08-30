import Foundation
import CryptoKit

// Runs the convention-audit suite over a project directory. The worker always
// gets the audit report and decides what to do to keep moving forward: this is
// informational, not a hard gate. Severities
// (.blocker / .warning / .notApplicable) tell the consumer how seriously to
// treat each result.
//
// Usage:
//   let report = await ConventionAuditRunner.audit(
//       projectDir: "/path/to/MyApp",
//       conventionsPath: "/path/to/mobile-app-conventions.md"
//   )
//   try report.markdown().write(toFile: "build_summary.md", atomically: true, encoding: .utf8)
public enum ConventionAuditRunner {

    public static func audit(
        projectDir: String,
        conventionsPath: String,
        // Empty by default: the brand a Siri phrase must lead with is the
        // caller's, not ours. Rule 13 reports "needs setup" rather than passing
        // vacuously when it is unset.
        brand: String = ""
    ) async -> ConventionAuditReport {
        let fm = FileManager.default

        // sha256 of the conventions doc - pinned per-job so downstream
        // consumers can detect when the spec has shifted.
        let conventionsVersion: String
        if let data = try? Data(contentsOf: URL(fileURLWithPath: conventionsPath)) {
            let digest = SHA256.hash(data: data)
            conventionsVersion = digest.map { String(format: "%02x", $0) }.joined()
        } else {
            conventionsVersion = "missing"
        }

        let projectURL = URL(fileURLWithPath: projectDir)
        let allFiles = enumerateProjectFiles(at: projectURL, fm: fm)

        var checks: [RuleCheck] = []
        checks.append(auditRule6_FlatToolbar(files: allFiles, fm: fm))
        checks.append(auditRule7_WCAGContrast(files: allFiles, fm: fm))
        checks.append(auditRule8_DynamicType(files: allFiles, fm: fm))
        checks.append(auditRule9_PrivacyManifest(projectDir: projectDir, fm: fm))
        checks.append(auditRule10_VersionSync(files: allFiles, fm: fm))
        checks.append(auditRule12_AppGroup(files: allFiles, fm: fm))
        checks.append(auditRule13_SiriBrandPhrases(files: allFiles, fm: fm, brand: brand))
        checks.append(auditRule16_SignInWithApple(files: allFiles, fm: fm))
        checks.append(auditRule27_UniversalLinks(files: allFiles, fm: fm))
        checks.append(auditRule29_ExportCompliance(files: allFiles, fm: fm))

        return ConventionAuditReport(
            timestamp: Date(),
            projectDir: projectDir,
            conventionsVersion: conventionsVersion,
            checks: checks
        )
    }

    // MARK: - File enumeration

    static func enumerateProjectFiles(at root: URL, fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            // Skip build / vendor noise.
            let p = url.path
            if p.contains("/.build/") || p.contains("/DerivedData/") ||
                p.contains("/Pods/") || p.contains("/node_modules/") {
                continue
            }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if vals?.isRegularFile == true {
                out.append(url)
            }
        }
        return out
    }

    // MARK: - Rule 6 (Toolbar - flat, not Liquid Glass pill)

    static func auditRule6_FlatToolbar(files: [URL], fm: FileManager) -> RuleCheck {
        let viewFiles = files.filter { $0.pathExtension == "swift" }
        var sawSafeAreaInsetTop = false
        var sawHiddenNavToolbar = false
        var sawDefaultTopBarTrailing = false

        for url in viewFiles {
            guard let txt = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if txt.contains(".safeAreaInset(edge: .top)") {
                sawSafeAreaInsetTop = true
            }
            if txt.contains(".toolbar(.hidden, for: .navigationBar)") {
                sawHiddenNavToolbar = true
            }
            if txt.contains("ToolbarItemGroup(placement: .topBarTrailing)") ||
                txt.contains("ToolbarItem(placement: .topBarTrailing)") {
                sawDefaultTopBarTrailing = true
            }
        }
        let pass = sawSafeAreaInsetTop && sawHiddenNavToolbar && !sawDefaultTopBarTrailing
        let detail: String
        if pass {
            detail = "Custom safeAreaInset(edge:.top) header in use AND nav toolbar hidden - no iOS-26 pill capsules."
        } else {
            var notes: [String] = []
            if !sawSafeAreaInsetTop { notes.append("missing custom .safeAreaInset(edge:.top) header") }
            if !sawHiddenNavToolbar { notes.append("missing .toolbar(.hidden, for:.navigationBar)") }
            if sawDefaultTopBarTrailing { notes.append("found default .topBarTrailing toolbar usage") }
            detail = notes.joined(separator: "; ")
        }
        return RuleCheck(
            ruleNumber: 6,
            ruleHeadline: "Toolbar buttons: flat, not iOS-26-Liquid-Glass-pill",
            passed: pass,
            severity: .warning,
            details: detail
        )
    }

    // MARK: - Rule 7 (WCAG AA contrast)

    static func auditRule7_WCAGContrast(files: [URL], fm: FileManager) -> RuleCheck {
        // Pick up Colors.swift OR any Color*.swift.
        let colorFiles = files.filter { url in
            let n = url.lastPathComponent
            return n == "Colors.swift" || (n.hasPrefix("Color") && n.hasSuffix(".swift"))
        }
        if colorFiles.isEmpty {
            return RuleCheck(
                ruleNumber: 7,
                ruleHeadline: "WCAG AA contrast on every (bg, fg) pair",
                passed: true,
                severity: .notApplicable,
                details: "No Colors.swift / Color*.swift found - nothing to audit."
            )
        }
        var literals: [ParsedColorLiteral] = []
        for url in colorFiles {
            guard let txt = try? String(contentsOf: url, encoding: .utf8) else { continue }
            literals.append(contentsOf: SwiftColorLiteralParser.parse(source: txt))
        }
        if literals.isEmpty {
            return RuleCheck(
                ruleNumber: 7,
                ruleHeadline: "WCAG AA contrast on every (bg, fg) pair",
                passed: true,
                severity: .notApplicable,
                details: "Color file(s) found but no parseable Color(red:green:blue:) literals."
            )
        }

        // Heuristic pairing: every variable whose name contains "bg" or
        // "background" or "surface" is a background candidate; every
        // variable whose name contains "text", "label", "fg", "foreground",
        // "primary", "title", "headline", "body", "caption" is a foreground
        // candidate. If neither side resolves, fall back to all-pairs over
        // the literal set so we still surface obvious failures.
        let backgrounds = literals.filter { lit in
            let n = (lit.name ?? "").lowercased()
            return n.contains("bg") || n.contains("background") || n.contains("surface")
        }
        let foregrounds = literals.filter { lit in
            let n = (lit.name ?? "").lowercased()
            return n.contains("text") || n.contains("label") ||
                   n.contains("fg") || n.contains("foreground") ||
                   n.contains("primary") || n.contains("title") ||
                   n.contains("headline") || n.contains("body") ||
                   n.contains("caption")
        }
        let pairs: [(ParsedColorLiteral, ParsedColorLiteral)]
        if !backgrounds.isEmpty && !foregrounds.isEmpty {
            var p: [(ParsedColorLiteral, ParsedColorLiteral)] = []
            for bg in backgrounds {
                for fg in foregrounds {
                    p.append((bg, fg))
                }
            }
            pairs = p
        } else {
            // All-pairs fallback.
            var p: [(ParsedColorLiteral, ParsedColorLiteral)] = []
            for i in 0..<literals.count {
                for j in (i+1)..<literals.count {
                    p.append((literals[i], literals[j]))
                }
            }
            pairs = p
        }

        var failures: [String] = []
        for (bg, fg) in pairs {
            let ratio = WCAGContrastChecker.contrastRatio(bg.color, fg.color)
            let largeText = fg.isLikelyLargeText
            if !WCAGContrastChecker.passesAA(ratio: ratio, isLargeText: largeText) {
                let bgName = bg.name ?? "rgb(\(bg.color.r),\(bg.color.g),\(bg.color.b))"
                let fgName = fg.name ?? "rgb(\(fg.color.r),\(fg.color.g),\(fg.color.b))"
                let needed = largeText ? "3.0" : "4.5"
                failures.append("\(fgName) on \(bgName) ratio=\(String(format: "%.2f", ratio)) <\(needed):1")
            }
        }

        let pass = failures.isEmpty
        let detail = pass
            ? "All \(pairs.count) (bg,fg) pairs ≥ AA threshold."
            : "WCAG AA failures: \(failures.joined(separator: ", "))"
        return RuleCheck(
            ruleNumber: 7,
            ruleHeadline: "WCAG AA contrast on every (bg, fg) pair",
            passed: pass,
            severity: .blocker,
            details: detail
        )
    }

    // MARK: - Rule 8 (Dynamic Type)

    static func auditRule8_DynamicType(files: [URL], fm: FileManager) -> RuleCheck {
        let viewFiles = files.filter { url in
            url.pathExtension == "swift" &&
            (url.lastPathComponent.hasSuffix("View.swift") ||
             url.path.contains("/Views/") ||
             url.path.contains("/Sources/"))
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"Font\.system\(\s*size:\s*[0-9]+(?:\.[0-9]+)?"#,
            options: []
        ) else {
            return RuleCheck(
                ruleNumber: 8,
                ruleHeadline: "Dynamic Type all the way to AccessibilityXL",
                passed: true,
                severity: .warning,
                details: "Regex compile failed - skipped."
            )
        }
        var offending: [String] = []
        for url in viewFiles {
            guard let txt = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let nsTxt = txt as NSString
            let r = NSRange(location: 0, length: nsTxt.length)
            let ms = regex.matches(in: txt, options: [], range: r)
            if !ms.isEmpty {
                offending.append("\(url.lastPathComponent) (\(ms.count) hit\(ms.count == 1 ? "" : "s"))")
            }
        }
        let pass = offending.isEmpty
        let detail = pass
            ? "No fixed Font.system(size:) found in view files."
            : "Fixed-size fonts found: \(offending.joined(separator: ", "))"
        return RuleCheck(
            ruleNumber: 8,
            ruleHeadline: "Dynamic Type all the way to AccessibilityXL",
            passed: pass,
            severity: .warning,
            details: detail
        )
    }

    // MARK: - Rule 9 (Privacy manifest)

    static func auditRule9_PrivacyManifest(projectDir: String, fm: FileManager) -> RuleCheck {
        // Resources/PrivacyInfo.xcprivacy may live anywhere under the
        // project - try both the bare Resources/ and any Sources/<App>/Resources.
        let projectURL = URL(fileURLWithPath: projectDir)
        var candidates: [URL] = []
        guard let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return RuleCheck(
                ruleNumber: 9,
                ruleHeadline: "Privacy manifest is a launch blocker",
                passed: false,
                severity: .blocker,
                details: "Couldn't enumerate \(projectDir)."
            )
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "PrivacyInfo.xcprivacy" {
                candidates.append(url)
            }
        }
        guard let manifest = candidates.first else {
            return RuleCheck(
                ruleNumber: 9,
                ruleHeadline: "Privacy manifest is a launch blocker",
                passed: false,
                severity: .blocker,
                details: "No PrivacyInfo.xcprivacy found anywhere under \(projectDir)."
            )
        }
        guard let data = try? Data(contentsOf: manifest),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return RuleCheck(
                ruleNumber: 9,
                ruleHeadline: "Privacy manifest is a launch blocker",
                passed: false,
                severity: .blocker,
                details: "Found \(manifest.path) but it failed plist parse."
            )
        }
        let required = ["NSPrivacyAccessedAPITypes", "NSPrivacyTracking", "NSPrivacyCollectedDataTypes"]
        let missing = required.filter { plist[$0] == nil }
        if missing.isEmpty {
            return RuleCheck(
                ruleNumber: 9,
                ruleHeadline: "Privacy manifest is a launch blocker",
                passed: true,
                severity: .blocker,
                details: "\(manifest.lastPathComponent) parsed; all required keys present."
            )
        } else {
            return RuleCheck(
                ruleNumber: 9,
                ruleHeadline: "Privacy manifest is a launch blocker",
                passed: false,
                severity: .blocker,
                details: "Missing required keys: \(missing.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Rule 10 (Multi-target version sync)

    static func auditRule10_VersionSync(files: [URL], fm: FileManager) -> RuleCheck {
        let infoPlists = files.filter { $0.lastPathComponent == "Info.plist" }
        guard !infoPlists.isEmpty else {
            return RuleCheck(
                ruleNumber: 10,
                ruleHeadline: "Multi-target version sync",
                passed: true,
                severity: .notApplicable,
                details: "No Info.plist files found under Sources/."
            )
        }
        var seen: [(URL, String?, String?)] = []
        for url in infoPlists {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any] else {
                continue
            }
            seen.append((
                url,
                plist["CFBundleShortVersionString"] as? String,
                plist["CFBundleVersion"] as? String
            ))
        }
        guard !seen.isEmpty else {
            return RuleCheck(
                ruleNumber: 10,
                ruleHeadline: "Multi-target version sync",
                passed: true,
                severity: .notApplicable,
                details: "Info.plist files found but none parsed cleanly."
            )
        }
        let shorts = Set(seen.compactMap { $0.1 })
        let bundles = Set(seen.compactMap { $0.2 })
        let pass = shorts.count <= 1 && bundles.count <= 1
        let detail: String
        if pass {
            let s = shorts.first ?? "(unset)"
            let b = bundles.first ?? "(unset)"
            detail = "Versions synced across \(seen.count) Info.plist file(s): short=\(s), bundle=\(b)."
        } else {
            detail = "Mismatch - short versions: \(shorts.sorted()); build versions: \(bundles.sorted())."
        }
        return RuleCheck(
            ruleNumber: 10,
            ruleHeadline: "Multi-target version sync",
            passed: pass,
            severity: .blocker,
            details: detail
        )
    }

    // MARK: - Rule 12 (App Group for extensions)

    static func auditRule12_AppGroup(files: [URL], fm: FileManager) -> RuleCheck {
        let swiftFiles = files.filter { $0.pathExtension == "swift" }
        // Identify extension targets by path conventions: WidgetExtension/,
        // ShareExtension/, NotificationServiceExtension/, etc.
        let extensionFiles = swiftFiles.filter { url in
            let p = url.path
            return p.contains("Widget") || p.contains("ShareExtension") ||
                   p.contains("NotificationService") || p.contains("Extension/")
        }
        if extensionFiles.isEmpty {
            return RuleCheck(
                ruleNumber: 12,
                ruleHeadline: "App Group for extensions",
                passed: true,
                severity: .notApplicable,
                details: "No extension-target source files found."
            )
        }
        var standardCallers: [String] = []
        for url in extensionFiles {
            guard let txt = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Allow `UserDefaults(suiteName: "group.<team>.<app>")`. Flag
            // only if the file uses bare `UserDefaults.standard`.
            if txt.contains("UserDefaults.standard") {
                standardCallers.append(url.lastPathComponent)
            }
        }
        let pass = standardCallers.isEmpty
        let detail = pass
            ? "All \(extensionFiles.count) extension source(s) avoid UserDefaults.standard."
            : "Extension files using UserDefaults.standard: \(standardCallers.joined(separator: ", "))"
        return RuleCheck(
            ruleNumber: 12,
            ruleHeadline: "App Group for extensions",
            passed: pass,
            severity: .blocker,
            details: detail
        )
    }

    // MARK: - Rule 13 (Siri brand-leading phrases)

    static func auditRule13_SiriBrandPhrases(files: [URL], fm: FileManager, brand: String) -> RuleCheck {
        let intentFiles = files.filter { url in
            let n = url.lastPathComponent
            return url.pathExtension == "swift" &&
                   (n.contains("Intents") || n.contains("Shortcuts"))
        }
        if intentFiles.isEmpty {
            return RuleCheck(
                ruleNumber: 13,
                ruleHeadline: "Siri / App Intents: brand-leading phrases ALWAYS",
                passed: true,
                severity: .notApplicable,
                details: "No *Intents*.swift / *Shortcuts*.swift files found."
            )
        }
        // No brand configured: there is nothing to check phrases against, and
        // silently passing would read as a green rule that never ran.
        let brandNeedle = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if brandNeedle.isEmpty {
            return RuleCheck(
                ruleNumber: 13,
                ruleHeadline: "Siri / App Intents: brand-leading phrases ALWAYS",
                passed: true,
                severity: .notApplicable,
                details: "No brand configured, pass a `brand` to check Siri phrases."
            )
        }
        // Match `phrases: [ ... ]` blocks. Any string literal in that block
        // missing the brand is a fail.
        let phrasePattern = #"phrases:\s*\[(.*?)\]"#
        guard let regex = try? NSRegularExpression(
            pattern: phrasePattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return RuleCheck(
                ruleNumber: 13,
                ruleHeadline: "Siri / App Intents: brand-leading phrases ALWAYS",
                passed: true,
                severity: .warning,
                details: "Regex compile failed - skipped."
            )
        }
        let strLitRegex = try? NSRegularExpression(pattern: #""([^"]+)""#, options: [])
        var sawAny = false
        var failures: [String] = []
        for url in intentFiles {
            guard let txt = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let nsTxt = txt as NSString
            let blocks = regex.matches(in: txt, options: [], range: NSRange(location: 0, length: nsTxt.length))
            for b in blocks {
                guard b.numberOfRanges >= 2 else { continue }
                sawAny = true
                let block = nsTxt.substring(with: b.range(at: 1))
                let nsBlock = block as NSString
                let lits = strLitRegex?.matches(
                    in: block,
                    options: [],
                    range: NSRange(location: 0, length: nsBlock.length)
                ) ?? []
                for l in lits {
                    guard l.numberOfRanges >= 2 else { continue }
                    let phrase = nsBlock.substring(with: l.range(at: 1))
                    if !phrase.lowercased().contains(brandNeedle.lowercased()) {
                        failures.append("\(url.lastPathComponent): \"\(phrase)\"")
                    }
                }
            }
        }
        if !sawAny {
            return RuleCheck(
                ruleNumber: 13,
                ruleHeadline: "Siri / App Intents: brand-leading phrases ALWAYS",
                passed: true,
                severity: .notApplicable,
                details: "Intents files found but no `phrases:` arrays."
            )
        }
        let pass = failures.isEmpty
        let detail = pass
            ? "All Siri phrases include brand `\(brandNeedle)`."
            : "Phrases missing brand `\(brandNeedle)`: \(failures.joined(separator: "; "))"
        return RuleCheck(
            ruleNumber: 13,
            ruleHeadline: "Siri / App Intents: brand-leading phrases ALWAYS",
            passed: pass,
            severity: .warning,
            details: detail
        )
    }

    // MARK: - Rule 16 (Sign in with Apple)

    static func auditRule16_SignInWithApple(files: [URL], fm: FileManager) -> RuleCheck {
        let authFiles = files.filter { url in
            let n = url.lastPathComponent
            return url.pathExtension == "swift" &&
                   (n.contains("LoginView") || n.contains("AuthView") ||
                    n.contains("SignIn") || n.contains("SignUp"))
        }
        if authFiles.isEmpty {
            return RuleCheck(
                ruleNumber: 16,
                ruleHeadline: "Sign in with Apple",
                passed: true,
                severity: .notApplicable,
                details: "No auth surface found."
            )
        }
        var sawSIWA = false
        for url in authFiles {
            guard let txt = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if txt.contains("SignInWithAppleButton") ||
                txt.contains("import AuthenticationServices") {
                sawSIWA = true
                break
            }
        }
        return RuleCheck(
            ruleNumber: 16,
            ruleHeadline: "Sign in with Apple",
            passed: sawSIWA,
            severity: .warning,
            details: sawSIWA
                ? "Auth surface uses SignInWithAppleButton / AuthenticationServices."
                : "Auth surface present but no SignInWithAppleButton / AuthenticationServices import."
        )
    }

    // MARK: - Rule 27 (Universal Links)

    static func auditRule27_UniversalLinks(files: [URL], fm: FileManager) -> RuleCheck {
        let entitlementFiles = files.filter { $0.pathExtension == "entitlements" }
        if entitlementFiles.isEmpty {
            return RuleCheck(
                ruleNumber: 27,
                ruleHeadline: "Universal Links",
                passed: true,
                severity: .notApplicable,
                details: "No .entitlements files found."
            )
        }
        for url in entitlementFiles {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any] else {
                continue
            }
            if let domains = plist["com.apple.developer.associated-domains"] as? [String] {
                // Any applinks: entry satisfies the rule. The domain belongs to
                // whoever is being audited, so we check that one is declared,
                // never which one.
                if let link = domains.first(where: { $0.hasPrefix("applinks:") }) {
                    return RuleCheck(
                        ruleNumber: 27,
                        ruleHeadline: "Universal Links",
                        passed: true,
                        severity: .warning,
                        details: "\(url.lastPathComponent) declares \(link)."
                    )
                }
            }
        }
        return RuleCheck(
            ruleNumber: 27,
            ruleHeadline: "Universal Links",
            passed: false,
            severity: .warning,
            details: "No entitlement declares an applinks: associated domain."
        )
    }

    // MARK: - Rule 29 (Export Compliance)

    static func auditRule29_ExportCompliance(files: [URL], fm: FileManager) -> RuleCheck {
        let infoPlists = files.filter { $0.lastPathComponent == "Info.plist" }
        if infoPlists.isEmpty {
            return RuleCheck(
                ruleNumber: 29,
                ruleHeadline: "Export Compliance",
                passed: false,
                severity: .blocker,
                details: "No Info.plist found - ITSAppUsesNonExemptEncryption cannot be checked."
            )
        }
        var setCount = 0
        for url in infoPlists {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any] else {
                continue
            }
            if plist["ITSAppUsesNonExemptEncryption"] != nil {
                setCount += 1
            }
        }
        let pass = setCount == infoPlists.count && setCount > 0
        let detail = pass
            ? "ITSAppUsesNonExemptEncryption explicitly set in all \(setCount) Info.plist file(s)."
            : "Missing ITSAppUsesNonExemptEncryption in \(infoPlists.count - setCount) of \(infoPlists.count) Info.plist file(s)."
        return RuleCheck(
            ruleNumber: 29,
            ruleHeadline: "Export Compliance",
            passed: pass,
            severity: .blocker,
            details: detail
        )
    }
}
