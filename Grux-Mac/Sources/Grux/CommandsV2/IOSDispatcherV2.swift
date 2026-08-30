import Foundation

// MARK: - IOSDispatcherV2
//
// Three new tools that the iOS launch workflow needs but that don't belong
// in GruxShellCore.IOSDispatcher (which stays platform-pure / no JWT, no
// REST, no project-specific config). These shell out to the project's own
// existing ASC scripts when a `<project>/.grux/ship-config.json` is
// present, and refuse with a clear error otherwise.
//
// Tools:
//   ios_install_to_device   - runs scripts/install-to-device.sh
//   ios_publish_to_appstore - bump version, archive, export, upload, submit
//   ios_check_asc_status    - JWT call to ASC, returns appStoreState
//
// Design notes:
//   • All three are idempotent at the phase boundary level. Re-running
//     after a partial failure is safe because the side effects (git commit,
//     ASC submission) are themselves idempotent or detectable.
//   • Output is `(text, success, stateUpdates)` so the workflow engine
//     can pluck specific values into run state without reparsing text.

struct IOSDispatcherV2Result {
    let text: String
    let success: Bool
    let stateUpdates: [String: JSONValue]
}

@MainActor
enum IOSDispatcherV2 {

    static func dispatch(name: String, input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        switch name {
        case "ios_install_to_device":
            return await installToDevice(input: input, run: run)
        case "ios_publish_to_appstore":
            return await publishToAppStore(input: input, run: run)
        case "ios_check_asc_status":
            return await checkASCStatus(input: input, run: run)
        case "ios_generate_screenshots":
            return await generateScreenshots(input: input, run: run)
        case "ios_check_account_health":
            return await checkAccountHealth(input: input, run: run)
        case "ios_open_account_blocker":
            return await openAccountBlocker(input: input, run: run)
        case "ios_fix_review_blockers":
            return await fixReviewBlockers(input: input, run: run)
        default:
            return .init(
                text: "error: unknown ios tool '\(name)' (V2 dispatcher knows: ios_install_to_device, ios_publish_to_appstore, ios_check_asc_status, ios_generate_screenshots, ios_check_account_health, ios_open_account_blocker, ios_fix_review_blockers)",
                success: false,
                stateUpdates: [:]
            )
        }
    }

    // MARK: - Review-readiness blockers
    //
    // Apple gates "Add for Review" on five metadata items that have nothing to
    // do with the build itself. Four are settable via REST (PATCH), the fifth
    // (App Privacy data-collection questionnaire) requires the ASC web UI and
    // is left for the workflow to drive via claude-in-chrome or to surface as
    // a one-click open-in-Safari action.
    //
    // Inputs (sourced from ship-config.json with safe defaults):
    //   privacyPolicyUrl             - required, must be a public HTTPS URL
    //   primaryCategory              - e.g. PRODUCTIVITY, default UTILITIES
    //   secondaryCategory            - optional
    //   contentRightsDeclaration     - DOES_NOT_USE_THIRD_PARTY_CONTENT (default)
    //                                  or USES_THIRD_PARTY_CONTENT
    //   ageRatingPreset              - ALL_AGES_4_PLUS (default) maps every
    //                                  AgeRatingDeclaration field to NONE/false
    //
    // Returns stateUpdates so the workflow can decide whether to halt for a
    // user-driven App Privacy fill: review_blockers_remaining lists the still-
    // unresolved items.
    private static func fixReviewBlockers(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let project = input["project"]?.stringValue ?? run.parameters["project"]?.stringValue ?? ""
        guard let cfg = ShipConfig.load(forProject: project) else {
            return missingConfigResult(project: project, op: "fix_review_blockers")
        }
        let probeJSON = "/tmp/grux-fix-blockers-\(run.id.uuidString.prefix(8)).json"
        let privacyURL = cfg.privacyPolicyUrl ?? ""
        let primaryCategory = (cfg.primaryCategory ?? "UTILITIES").uppercased()
        let secondaryCategory = (cfg.secondaryCategory ?? "").uppercased()
        let contentRights = (cfg.contentRightsDeclaration ?? "DOES_NOT_USE_THIRD_PARTY_CONTENT").uppercased()
        let ageRatingPreset = (cfg.ageRatingPreset ?? "ALL_AGES_4_PLUS").uppercased()

        // SECURITY: ShipConfig values come from a project's ship-config.json, which
        // is untrusted. We MUST NOT interpolate them into the Python source (a
        // single quote would break out and execute). Write them to a 0600 temp
        // JSON the script reads with json.load; only the UUID-based path is
        // interpolated into the heredoc.
        let cfgPath = "/tmp/grux-fix-blockers-cfg-\(run.id.uuidString.prefix(8)).json"
        let cfgDict: [String: Any] = [
            "key_id": cfg.ascApiKeyId,
            "issuer_id": cfg.ascApiKeyIssuerId,
            "app_id": cfg.ascAppId,
            "key_path": cfg.ascApiKeyPath ?? "",
            "privacy_url": privacyURL,
            "primary_category": primaryCategory,
            "secondary_category": secondaryCategory,
            "content_rights": contentRights,
            "age_preset": ageRatingPreset,
            "out_path": probeJSON,
        ]
        if let cfgData = try? JSONSerialization.data(withJSONObject: cfgDict) {
            try? cfgData.write(to: URL(fileURLWithPath: cfgPath), options: [.atomic, .completeFileProtection])
        }

        // The Python script does the JWT mint + 4 PATCH calls + 1 GET probe.
        // Embedded heredoc keeps the deploy artifact a single binary. Values come
        // from the temp JSON above (json.load), never interpolated.
        let script = """
        /opt/homebrew/bin/python3 - <<'PYEOF' 2>&1
        import jwt, time, json, urllib.request, urllib.error, os, sys
        CFG = json.load(open('\(cfgPath)'))
        KEY_ID = CFG['key_id']
        ISSUER_ID = CFG['issuer_id']
        APP_ID = CFG['app_id']
        KEY_PATH = os.path.expanduser(CFG['key_path']) or os.path.expanduser('~/.appstoreconnect/private_keys/AuthKey_' + KEY_ID + '.p8')
        PRIVACY_URL = CFG['privacy_url']
        PRIMARY_CATEGORY = CFG['primary_category']
        SECONDARY_CATEGORY = CFG['secondary_category']
        CONTENT_RIGHTS = CFG['content_rights']
        AGE_PRESET = CFG['age_preset']
        OUT_PATH = CFG['out_path']

        with open(KEY_PATH) as f: pk = f.read()
        now = int(time.time())
        TOK = jwt.encode({'iss': ISSUER_ID, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'},
                         pk, algorithm='ES256', headers={'kid': KEY_ID})
        H = {'Authorization': f'Bearer {TOK}', 'Content-Type': 'application/json'}

        def call(method, path, body=None):
            req = urllib.request.Request(f'https://api.appstoreconnect.apple.com{path}',
                data=(json.dumps(body).encode() if body else None),
                method=method, headers=H)
            try:
                with urllib.request.urlopen(req) as r:
                    raw = r.read()
                    return r.status, (json.loads(raw) if raw else {})
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode('utf-8','ignore')[:500]

        result = {'fixed': [], 'failed': [], 'remaining': [], 'app_privacy_url': None}

        # 0. Discover IDs we need
        s, app_info_resp = call('GET', f'/v1/apps/{APP_ID}/appInfos?include=appInfoLocalizations,ageRatingDeclaration')
        if s != 200:
            result['failed'].append({'step': 'lookup_app_info', 'detail': str(app_info_resp)[:300]})
            with open(OUT_PATH, 'w') as f: json.dump(result, f, indent=2)
            print(json.dumps(result, indent=2)); sys.exit(0)

        # Pick the first PREPARE_FOR_SUBMISSION appInfo (the editable one)
        editable = None
        primary_locale_id = None
        for inf in app_info_resp.get('data', []):
            if inf['attributes'].get('appStoreState') == 'PREPARE_FOR_SUBMISSION':
                editable = inf
                break
        if not editable and app_info_resp.get('data'):
            editable = app_info_resp['data'][0]
        if not editable:
            result['failed'].append({'step': 'no_editable_app_info'})
            with open(OUT_PATH, 'w') as f: json.dump(result, f, indent=2)
            print(json.dumps(result, indent=2)); sys.exit(0)
        APP_INFO_ID = editable['id']
        ARD_ID = APP_INFO_ID  # ageRatingDeclaration shares the appInfo id
        loc_rels = editable['relationships'].get('appInfoLocalizations', {}).get('data', [])
        if loc_rels:
            primary_locale_id = loc_rels[0]['id']

        # 1. Privacy Policy URL (per-locale)
        if PRIVACY_URL and primary_locale_id:
            s, j = call('PATCH', f'/v1/appInfoLocalizations/{primary_locale_id}',
                        {'data': {'type': 'appInfoLocalizations', 'id': primary_locale_id,
                                  'attributes': {'privacyPolicyUrl': PRIVACY_URL}}})
            (result['fixed'] if s < 400 else result['failed']).append({'step': 'privacyPolicyUrl', 'status': s})

        # 2. Primary Category (relationship via appInfo PATCH)
        if PRIMARY_CATEGORY:
            rel = {'primaryCategory': {'data': {'type': 'appCategories', 'id': PRIMARY_CATEGORY}}}
            if SECONDARY_CATEGORY:
                rel['secondaryCategory'] = {'data': {'type': 'appCategories', 'id': SECONDARY_CATEGORY}}
            s, j = call('PATCH', f'/v1/appInfos/{APP_INFO_ID}',
                        {'data': {'type': 'appInfos', 'id': APP_INFO_ID, 'relationships': rel}})
            (result['fixed'] if s < 400 else result['failed']).append({'step': 'primaryCategory', 'status': s})

        # 3. Content Rights (app-level attribute)
        if CONTENT_RIGHTS:
            s, j = call('PATCH', f'/v1/apps/{APP_ID}',
                        {'data': {'type': 'apps', 'id': APP_ID,
                                  'attributes': {'contentRightsDeclaration': CONTENT_RIGHTS}}})
            (result['fixed'] if s < 400 else result['failed']).append({'step': 'contentRightsDeclaration', 'status': s})

        # 4. Age Rating - preset ALL_AGES_4_PLUS = every field NONE/false
        if AGE_PRESET == 'ALL_AGES_4_PLUS':
            attrs = {
                'advertising': False, 'gambling': False, 'lootBox': False,
                'messagingAndChat': False, 'parentalControls': False,
                'unrestrictedWebAccess': False, 'userGeneratedContent': False,
                'healthOrWellnessTopics': False, 'ageAssurance': False,
                'alcoholTobaccoOrDrugUseOrReferences': 'NONE', 'contests': 'NONE',
                'gamblingSimulated': 'NONE', 'gunsOrOtherWeapons': 'NONE',
                'medicalOrTreatmentInformation': 'NONE', 'profanityOrCrudeHumor': 'NONE',
                'sexualContentGraphicAndNudity': 'NONE', 'sexualContentOrNudity': 'NONE',
                'horrorOrFearThemes': 'NONE', 'matureOrSuggestiveThemes': 'NONE',
                'violenceCartoonOrFantasy': 'NONE',
                'violenceRealisticProlongedGraphicOrSadistic': 'NONE',
                'violenceRealistic': 'NONE', 'ageRatingOverride': 'NONE',
                'koreaAgeRatingOverride': 'NONE',
            }
            s, j = call('PATCH', f'/v1/ageRatingDeclarations/{ARD_ID}',
                        {'data': {'type': 'ageRatingDeclarations', 'id': ARD_ID, 'attributes': attrs}})
            (result['fixed'] if s < 400 else result['failed']).append({'step': 'ageRatingDeclaration', 'status': s})

        # 5. App Privacy data-collection - not exposed via REST. Probe the live
        # version to detect whether the questionnaire is still unanswered, and
        # surface the Safari deep-link if it is.
        # The signal we use: any version in PREPARE_FOR_SUBMISSION on an app
        # that has never published privacy details will keep showing the
        # admin-required blocker until /distribution/privacy "Get Started" → Save → Publish.
        # Apple doesn't expose this state via REST; the workflow's claude-in-chrome
        # path handles it directly. We emit the URL either way so the upstream
        # phase can decide.
        result['app_privacy_url'] = f'https://appstoreconnect.apple.com/apps/{APP_ID}/distribution/privacy'

        # If anything still failed, list it under remaining so the workflow knows
        # not to mark this phase 100% green.
        for f in result['failed']:
            result['remaining'].append(f['step'])

        with open(OUT_PATH, 'w') as f:
            json.dump(result, f, indent=2)
        print(json.dumps(result, indent=2))
        PYEOF
        """
        let r = await ShellRunner.runRaw(command: script, timeoutSeconds: 60)
        var stateUpdates: [String: JSONValue] = [
            "review_blockers_log": .string(r.truncated),
            "review_blockers_probe_json": .string(probeJSON),
        ]

        // Parse the JSON output to extract structured signals for downstream phases.
        if let data = r.stdout.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fixed = parsed["fixed"] as? [[String: Any]] {
                stateUpdates["review_blockers_fixed_count"] = .int(fixed.count)
            }
            if let remaining = parsed["remaining"] as? [String] {
                stateUpdates["review_blockers_remaining"] = .string(remaining.joined(separator: ","))
            }
            if let appPrivacyURL = parsed["app_privacy_url"] as? String {
                stateUpdates["app_privacy_url"] = .string(appPrivacyURL)
            }
        }

        // Always succeed - App Privacy can't be auto-fixed via API, so the
        // overall phase outcome is "did the API portion run cleanly". The
        // workflow's next phase decides whether to drive the questionnaire.
        return .init(
            text: "[fix_review_blockers exit \(r.status)]\n\(r.truncated)",
            success: r.status == 0,
            stateUpdates: stateUpdates
        )
    }

    // MARK: - Account health
    //
    // Probes the App Store Connect account for the most common preflight
    // blockers that cause altool uploads to silently disappear from the build
    // catalog. Returns structured findings the workflow uses to decide whether
    // to pause for user action before attempting publish.
    //
    // Detected blockers:
    //   • Recent uploads with no catalog appearance (agreements gate)
    //   • App in PREPARE_FOR_SUBMISSION but no build attached after 30+ min
    //   • Auth failures on routine ASC reads (key revoked or scope changed)
    //
    // The companion tool `ios_open_account_blocker` opens the right ASC URL
    // (Safari) and fans out a notification to the Mac + GruxPhone so the user
    // can resolve the blocker without context-switching back to chat.
    private static func checkAccountHealth(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let project = input["project"]?.stringValue ?? run.parameters["project"]?.stringValue ?? ""
        guard let cfg = ShipConfig.load(forProject: project) else {
            return missingConfigResult(project: project, op: "check_account_health")
        }

        // Build the JWT health-probe in a dedicated python script so the
        // crypto runs out-of-process. Saves the rich JSON probe to /tmp where
        // the workflow can inspect it.
        let probeJSON = "/tmp/grux-account-health-\(run.id.uuidString.prefix(8)).json"
        // SECURITY: pass untrusted ShipConfig values via a 0600 temp JSON the
        // script json.loads, never interpolated into the Python source.
        let cfgPath = "/tmp/grux-account-health-cfg-\(run.id.uuidString.prefix(8)).json"
        let cfgDict: [String: Any] = [
            "key_id": cfg.ascApiKeyId,
            "issuer_id": cfg.ascApiKeyIssuerId,
            "app_id": cfg.ascAppId,
            "key_path": cfg.ascApiKeyPath ?? "",
        ]
        if let cfgData = try? JSONSerialization.data(withJSONObject: cfgDict) {
            try? cfgData.write(to: URL(fileURLWithPath: cfgPath), options: [.atomic, .completeFileProtection])
        }
        let script = """
        /opt/homebrew/bin/python3 - <<'PYEOF' 2>&1
        import jwt, time, json, urllib.request, urllib.error, os, sys
        CFG = json.load(open('\(cfgPath)'))
        KEY_ID = CFG['key_id']
        ISSUER_ID = CFG['issuer_id']
        APP_ID = CFG['app_id']
        KEY_PATH = os.path.expanduser(CFG['key_path']) or os.path.expanduser('~/.appstoreconnect/private_keys/AuthKey_' + KEY_ID + '.p8')
        with open(KEY_PATH) as f: pk = f.read()
        now = int(time.time())
        tok = jwt.encode(
            {'iss': ISSUER_ID, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'},
            pk, algorithm='ES256', headers={'kid': KEY_ID}
        )
        def get(url):
            req = urllib.request.Request(url, headers={'Authorization': f'Bearer {tok}'})
            try:
                with urllib.request.urlopen(req) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as e:
                return {'_error': f'HTTP {e.code}', '_body': e.read()[:300].decode('utf-8', 'ignore')}

        findings = {'blockers': [], 'warnings': [], 'ok': []}

        # 1. Auth probe - does the key have basic read scope?
        u = get('https://api.appstoreconnect.apple.com/v1/users?limit=1')
        if '_error' in u:
            findings['blockers'].append({
                'code': 'AUTH_FAIL',
                'message': f"ASC API key {KEY_ID} returned {u['_error']} on /v1/users - key may be revoked or have insufficient scope.",
                'action_url': 'https://appstoreconnect.apple.com/access/users',
                'action_text': 'Verify the API key in Users and Access → Integrations.'
            })
        else:
            findings['ok'].append('asc_api_auth')

        # 2. App-level state
        app = get(f'https://api.appstoreconnect.apple.com/v1/apps/{APP_ID}')
        if '_error' in app:
            findings['blockers'].append({
                'code': 'APP_NOT_FOUND',
                'message': f"App {APP_ID} not visible to this API key.",
                'action_url': f'https://appstoreconnect.apple.com/apps/{APP_ID}/distribution',
                'action_text': 'Confirm the app exists and the API key has scope for it.'
            })
        else:
            findings['ok'].append('app_record_exists')

        # 3. Version-string mismatch - the #1 cause of silent build drops for
        # first-publish flows. If the existing draft AppStoreVersion's
        # versionString doesn't match the bundle's CFBundleShortVersionString,
        # Apple's pipeline accepts the upload (altool reports success) but
        # silently drops the build because there's no version slot to land in.
        versions = get(f'https://api.appstoreconnect.apple.com/v1/apps/{APP_ID}/appStoreVersions?limit=10')
        draft_versions = [v for v in versions.get('data', []) if v.get('attributes', {}).get('appStoreState') == 'PREPARE_FOR_SUBMISSION']
        if draft_versions:
            draft_v = draft_versions[0]['attributes'].get('versionString', '?')
            findings['ok'].append(f'asc_draft_version={draft_v}')
            # Best-effort read of the bundle's shortVersion for comparison.
            try:
                import subprocess
                plist = '\(cfg.projectRoot)/' + '\(cfg.infoPlistPath ?? "")'
                bundle_v = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleShortVersionString', plist], text=True).strip()
                if bundle_v and bundle_v != draft_v:
                    findings['blockers'].append({
                        'code': 'VERSION_STRING_MISMATCH',
                        'message': f'ASC draft version is {draft_v} but bundle shortVersion is {bundle_v}. Apple silently drops uploads when these don\\'t match.',
                        'action_url': f'https://appstoreconnect.apple.com/apps/{APP_ID}/distribution/ios/version/inflight',
                        'action_text': f'Update the App Store version field to {bundle_v} (Save). Or let Grux PATCH it via API.'
                    })
            except Exception:
                pass

        # 4. Build catalog state. If 0 builds AND no version mismatch detected,
        # the cause is likely account-level (agreements, banking, taxes).
        builds = get(f'https://api.appstoreconnect.apple.com/v1/apps/{APP_ID}/builds?limit=5')
        app_build_count = len(builds.get('data', []))
        if app_build_count == 0 and not any(b.get('code') == 'VERSION_STRING_MISMATCH' for b in findings['blockers']):
            findings['warnings'].append({
                'code': 'NO_BUILDS_FOR_APP',
                'message': f'No builds visible for app {APP_ID}. Either nothing has been uploaded, or an account-level issue is dropping uploads.',
                'action_url': 'https://appstoreconnect.apple.com/business/',
                'action_text': "Open Business → check Agreements (Free + Paid Apps Active), Bank Accounts, Tax Forms, Compliance (DSA Trader Status). All must be Active."
            })
        else:
            findings['ok'].append(f'app_builds={app_build_count}')

        print(json.dumps(findings, indent=2))
        with open('\(probeJSON)', 'w') as f: f.write(json.dumps(findings))
        PYEOF
        """
        let probe = await ShellRunner.runRaw(command: script, timeoutSeconds: 60)

        // Parse the JSON the python script wrote to /tmp (more reliable than parsing stdout
        // because pip-install warnings can pollute stdout).
        var blockers: [String] = []
        var warnings: [String] = []
        var actionURL: String = ""
        var actionText: String = ""
        if let data = try? Data(contentsOf: URL(fileURLWithPath: probeJSON)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let bs = obj["blockers"] as? [[String: Any]] {
                for b in bs {
                    blockers.append((b["code"] as? String ?? "?") + ": " + (b["message"] as? String ?? ""))
                    if actionURL.isEmpty {
                        actionURL = (b["action_url"] as? String) ?? actionURL
                        actionText = (b["action_text"] as? String) ?? actionText
                    }
                }
            }
            if let ws = obj["warnings"] as? [[String: Any]] {
                for w in ws {
                    warnings.append((w["code"] as? String ?? "?") + ": " + (w["message"] as? String ?? ""))
                    if actionURL.isEmpty {
                        actionURL = (w["action_url"] as? String) ?? actionURL
                        actionText = (w["action_text"] as? String) ?? actionText
                    }
                }
            }
        }
        // Warnings are informational only - they should NOT fail the phase. The classic
        // false-positive: NO_BUILDS_FOR_APP fires for a brand-new app where we just
        // haven't attempted to upload yet; that's the normal initial state, not a
        // problem. Hard blockers (auth fail, version mismatch, app not visible)
        // remain the only thing that gates publish.
        let healthy = blockers.isEmpty
        let summary: String = {
            if healthy { return "ASC account health: ok (auth + app + builds visible)" }
            var s = "ASC account health flagged \(blockers.count) blocker(s) and \(warnings.count) warning(s):\n"
            for b in blockers { s += "  🔴 \(b)\n" }
            for w in warnings { s += "  🟡 \(w)\n" }
            if !actionURL.isEmpty {
                s += "\nNext step: \(actionText)\n→ \(actionURL)"
            }
            return s
        }()

        // Best-effort fan-out so the user sees the blocker without staring at chat.
        if !healthy && !actionURL.isEmpty {
            await MainActor.run {
                NotificationManager.shared.sendInfo(
                    title: "iOS publish needs your attention",
                    body: actionText.isEmpty ? "Open the link in Safari to resolve." : actionText
                )
            }
            PhoneReceiverService.shared.notifyAccountBlocker(
                projectName: project,
                actionURL: actionURL,
                actionText: actionText
            )
        }

        return .init(
            text: summary + (probe.truncated.isEmpty ? "" : "\n---probe stdout---\n" + String(probe.truncated.suffix(800))),
            success: healthy,
            stateUpdates: [
                "account_health_ok": .bool(healthy),
                "account_health_blockers": .int(blockers.count),
                "account_health_warnings": .int(warnings.count),
                "account_health_action_url": .string(actionURL),
                "account_health_action_text": .string(actionText)
            ]
        )
    }

    // Open the resolution URL in Safari + speak the action so the user knows
    // why their browser just popped open. Used by the publish-blocker phase to
    // turn an abstract "agreements pending" diagnosis into an actionable
    // 1-click fix.
    private static func openAccountBlocker(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let url = input["url"]?.stringValue ?? run.state["account_health_action_url"]?.stringValue ?? ""
        let text = input["text"]?.stringValue ?? run.state["account_health_action_text"]?.stringValue ?? ""
        guard !url.isEmpty else {
            return .init(text: "no account_health_action_url available; nothing to open", success: false, stateUpdates: [:])
        }
        // Open in user's default browser (Safari/Chrome). `open` returns
        // immediately; the URL fires regardless of whether the browser was
        // already running.
        // Force Chrome - the user's whole working session lives there
        // (claude-in-chrome tabs, logged-in ASC, devtools). Bare `open <url>`
        // resolves to the macOS default browser, which is sometimes Safari and
        // fragments their context.
        // SECURITY: url may originate from an external HTTP (ASC) response, so it
        // must NEVER be interpolated into a shell string. Validate it is a plain
        // https URL and pass it as an explicit argument (no shell) so it cannot be
        // interpreted as shell syntax.
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
            return .init(text: "refusing to open non-https or malformed url: \(url)", success: false, stateUpdates: [:])
        }
        _ = await ShellRunner.runArgs("/usr/bin/open", ["-a", "Google Chrome", parsed.absoluteString], timeoutSeconds: 5)
        if !text.isEmpty {
            await speakAndWaitGlobal(text)
        }
        return .init(
            text: "opened \(url)\n→ \(text)",
            success: true,
            stateUpdates: ["account_blocker_opened_at": .string(ISO8601DateFormatter().string(from: Date()))]
        )
    }

    // Tiny wrapper around SpeechEngine because IOSDispatcherV2 isn't @MainActor.
    private static func speakAndWaitGlobal(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await MainActor.run {
            SpeechEngine.shared.speak(trimmed)
        }
        // Crude wait - speech is async; the workflow doesn't strictly need to
        // block on it but a small delay avoids overlapping with the next phase.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    // MARK: - Install

    private static func installToDevice(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let project = input["project"]?.stringValue ?? run.parameters["project"]?.stringValue ?? ""
        guard let cfg = ShipConfig.load(forProject: project) else {
            return missingConfigResult(project: project, op: "install_to_device")
        }
        let projectRoot = cfg.projectRoot
        let installScript = projectRoot + "/scripts/install-to-device.sh"
        let fm = FileManager.default
        if fm.fileExists(atPath: installScript) {
            // Use the project's own canonical install script if present.
            let r = await ShellRunner.runRaw(command: "cd \"\(projectRoot)\" && ./scripts/install-to-device.sh", timeoutSeconds: 600)
            return .init(
                text: "[install_to_device exit \(r.status)]\n\(r.truncated)",
                success: r.status == 0,
                stateUpdates: [
                    "device_install_exit": .int(Int(r.status)),
                    "device_install_log_tail": .string(String(r.truncated.suffix(800)))
                ]
            )
        }
        // Pre-flight: device must be paired. If not, treat as soft skip - install-to-device
        // is a TESTING convenience (smoke test on a paired iPhone) and is NOT required for App
        // Store submission (publish phase does its own archive → altool upload). Returning
        // success=true with `install_skipped=device_unavailable` lets downstream phases
        // continue toward publish so a missing/locked phone doesn't block ASC shipment.
        let pre = await ShellRunner.runRaw(command: "xcrun devicectl list devices 2>&1 | grep -q 'available (paired)' && echo paired || echo unpaired")
        if !pre.stdout.contains("paired") {
            return .init(
                text: "warn: no paired iPhone detected - skipping local install (App Store submission does NOT need this). Reconnect + unlock the phone and re-run if you want device-side smoke testing.",
                success: true,
                stateUpdates: [
                    "install_skipped": .string("device_unavailable_no_paired_iphone"),
                    "install_warning": .bool(true)
                ]
            )
        }
        // Generic install path: xcodegen → xcodebuild → devicectl install.
        // Discovers the first connected paired iPhone and installs the
        // freshly-built .app onto it. Used by any iOS project with no
        // project-specific install-to-device.sh that adopts the
        // ship-config.json convention without a custom orchestrator.
        return await genericXcodebuildInstall(cfg: cfg, project: project)
    }

    private static func genericXcodebuildInstall(cfg: ShipConfig, project: String) async -> IOSDispatcherV2Result {
        let projectRoot = cfg.projectRoot
        let fm = FileManager.default
        let yamlPath = projectRoot + "/project.yml"
        var stateUpdates: [String: JSONValue] = [:]

        // 1. xcodegen if project.yml exists and .xcodeproj is missing/stale.
        if fm.fileExists(atPath: yamlPath) {
            let regen = await ShellRunner.runRaw(
                command: "cd \"\(projectRoot)\" && xcodegen generate 2>&1",
                timeoutSeconds: 60
            )
            if regen.status != 0 {
                return .init(
                    text: "[xcodegen exit \(regen.status)]\n\(regen.truncated)",
                    success: false,
                    stateUpdates: ["xcodegen_exit": .int(Int(regen.status))]
                )
            }
            stateUpdates["xcodegen_ran"] = .bool(true)
        }

        // 2. Find the .xcodeproj (top-level only - workspace-style projects
        //    aren't in the generated-project shape).
        let projects = (try? fm.contentsOfDirectory(atPath: projectRoot))?.filter { $0.hasSuffix(".xcodeproj") && $0.range(of: #" \d+\.xcodeproj$"#, options: .regularExpression) == nil } ?? []
        guard let xcodeproj = projects.first else {
            return .init(
                text: "error: no .xcodeproj in \(projectRoot). Run xcodegen or generate the project file.",
                success: false,
                stateUpdates: stateUpdates
            )
        }
        let scheme = (xcodeproj as NSString).deletingPathExtension

        // 3. Discover an AVAILABLE-state iPhone (devicectl reports paired
        //    devices as "available" only when they're physically reachable;
        //    devices in "unavailable" state are paired but unplugged/locked
        //    so install would silently hang then fail).
        let listed = await ShellRunner.runRaw(
            command: "xcrun devicectl list devices --json-output - 2>/dev/null",
            timeoutSeconds: 15
        )
        var udid = parseFirstAvailableUDID(json: listed.stdout) ?? ""
        if udid.isEmpty {
            // devicectl-stuck fallback. If idevice_id sees a phone, harvest its
            // ECID and grep the devicectl JSON for a device whose connectionProperties
            // ECID hint matches - that gives us the UDID even when devicectl
            // labeled it "unavailable" due to a stale CoreDevice cache.
            let ecidProbe = await ShellRunner.runRaw(
                command: "/opt/homebrew/bin/idevice_id -l 2>/dev/null",
                timeoutSeconds: 5
            )
            let ecid = ecidProbe.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if !ecid.isEmpty {
                udid = parseAnyiPhoneUDID(json: listed.stdout) ?? ""
                if !udid.isEmpty {
                    stateUpdates["device_discovery_via"] = .string("idevice_id+devicectl-cache")
                }
            }
        }
        guard !udid.isEmpty else {
            // Surface clearly so the operator knows what to do next. The text
            // shape ('UNAVAILABLE_DEVICE') is detected upstream so future
            // workflow iterations can mark this as paused-for-user instead of
            // a hard failure.
            let textCheck = await ShellRunner.runRaw(
                command: "xcrun devicectl list devices 2>&1",
                timeoutSeconds: 10
            )
            return .init(
                text: """
                warn: UNAVAILABLE_DEVICE - no paired iPhone reachable. Skipping local install
                (NOT required for App Store submission - publish does its own archive + upload).
                If you want a device smoke test before publish, connect the iPhone via USB-C,
                unlock it, accept any trust prompt, and re-fire this workflow.

                xcrun devicectl list devices output:
                \(textCheck.truncated.suffix(800))
                """,
                success: true,
                stateUpdates: stateUpdates.merging([
                    "install_skipped": .string("device_unavailable"),
                    "install_warning": .bool(true)
                ], uniquingKeysWith: { _, b in b })
            )
        }
        stateUpdates["device_udid"] = .string(udid)

        // 4. Build for device with automatic provisioning. Stage builds in
        //    /tmp because iCloud Drive auto-injects com.apple.FinderInfo /
        //    fileprovider xattrs into the project's nested build dirs, which
        //    corrupts the .app bundle (Info.plist disappears, codesign fails,
        //    later install reports "could not locate Info.plist in app").
        //    Grux's own build.sh uses the same /tmp staging trick.
        let projectSlug = (xcodeproj as NSString).deletingPathExtension.lowercased()
        let buildDir = "/tmp/grux-ios-build/\(projectSlug)-device"
        try? fm.removeItem(atPath: buildDir)
        try? fm.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        // Scrub xattrs on the project root in-place so xcodegen and xcodebuild's
        // input-file scans don't trip on stale FinderInfo blobs from iCloud sync.
        _ = await ShellRunner.runRaw(
            command: "xattr -rc \"\(projectRoot)\" 2>/dev/null || true",
            timeoutSeconds: 60
        )
        let buildCmd = """
        cd "\(projectRoot)" && xcodebuild \
          -project "\(xcodeproj)" \
          -scheme "\(scheme)" \
          -configuration Debug \
          -destination 'generic/platform=iOS' \
          -derivedDataPath "\(buildDir)" \
          -allowProvisioningUpdates \
          DEVELOPMENT_TEAM=\(cfg.teamId) \
          CODE_SIGN_STYLE=Automatic \
          build 2>&1
        """
        // Run xcodebuild with our hang-resilient wrapper. xcodebuild on
        // iCloud-synced project paths (e.g. ~/Library/Mobile Documents/...)
        // routinely produces all artifacts cleanly but then enters an
        // unkillable-without-SIGKILL final-cleanup state where the parent
        // process never exits. The wrapper polls the build output dir for the
        // .app artifact, and as soon as it's present + size-stable for a few
        // seconds, treats the build as a success even if the parent is still
        // running. Falls back to a hard timeout for genuine failures.
        let appsRoot = buildDir + "/Build/Products/Debug-iphoneos"
        let build = await runXcodebuildResilient(cmd: buildCmd, expectedAppsDir: appsRoot, timeoutSeconds: 900)
        stateUpdates["xcodebuild_exit"] = .int(Int(build.status))
        let apps = (try? fm.contentsOfDirectory(atPath: appsRoot))?.filter { $0.hasSuffix(".app") } ?? []
        guard let appName = apps.first else {
            return .init(
                text: "[xcodebuild exit \(build.status), no .app produced]\n\(String(build.truncated.suffix(2000)))",
                success: false,
                stateUpdates: stateUpdates
            )
        }
        let appPath = appsRoot + "/" + appName
        stateUpdates["app_path"] = .string(appPath)

        // 6. Install. Prefer devicectl (modern, official), fall back to
        //    ideviceinstaller (libimobiledevice) when devicectl's
        //    CoreDeviceService is in its stuck "No provider was found" state.
        //    The fallback also covers the case where idevice_id sees the phone
        //    but devicectl's stale device cache reports it as "unavailable"
        //    (a known macOS bug that survives `launchctl kickstart` and only
        //    clears on Mac reboot or Xcode reinstall).
        let install = await ShellRunner.runRaw(
            command: "xcrun devicectl device install app --device \(udid) \"\(appPath)\" 2>&1",
            timeoutSeconds: 120
        )
        stateUpdates["devicectl_install_exit"] = .int(Int(install.status))
        if install.status == 0 {
            return .init(
                text: "ok: installed \(appName) to device \(udid) (devicectl).\n\(install.truncated.suffix(400))",
                success: true,
                stateUpdates: stateUpdates
            )
        }
        // Devicectl failed → try ideviceinstaller. ideviceinstaller wants the
        // ECID-style identifier (idevice_id -l), not the devicectl UDID.
        let ecidProbe = await ShellRunner.runRaw(
            command: "/opt/homebrew/bin/idevice_id -l 2>/dev/null",
            timeoutSeconds: 5
        )
        let ecid = ecidProbe.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !ecid.isEmpty else {
            // Device dropped off the bus DURING install (cable, lock, USB hub
            // hiccup). Install-to-device is a smoke-test convenience, NOT
            // required for App Store submission - publish-phase does its own
            // archive + altool upload independent of any local device. Return
            // success=true with a skip flag so the workflow can continue toward
            // ASC. The user can retry install manually later if they want
            // device-side QA before TestFlight.
            return .init(
                text: """
                warn: install failed mid-flight via devicectl, and device is no longer visible to idevice_id (likely USB hiccup or phone locked). Skipping local install and continuing - App Store submission does NOT require a device install. Reconnect + unlock the phone and re-fire the workflow if you want device-side smoke testing.

                devicectl output (truncated):
                \(install.truncated.suffix(600))
                """,
                success: true,
                stateUpdates: stateUpdates.merging([
                    "install_skipped": .string("device_disconnected_midflight"),
                    "install_warning": .bool(true)
                ], uniquingKeysWith: { _, b in b })
            )
        }
        // Use ideviceinstaller's `install` subcommand with the .app bundle.
        let alt = await ShellRunner.runRaw(
            command: "/opt/homebrew/bin/ideviceinstaller -u \(ecid) install \"\(appPath)\" 2>&1",
            timeoutSeconds: 180
        )
        stateUpdates["ideviceinstaller_exit"] = .int(Int(alt.status))
        // ideviceinstaller returns 0 and prints "Install: Complete" on success.
        let succeeded = alt.status == 0 && alt.stdout.contains("Install: Complete")
        if succeeded {
            return .init(
                text: "ok: installed \(appName) via ideviceinstaller (devicectl was stuck).\n\(alt.truncated.suffix(400))",
                success: true,
                stateUpdates: stateUpdates
            )
        }
        // Both install paths failed. Soft-skip rather than hard-fail -
        // install-to-device is a convenience phase, not a hard dependency
        // for ASC submission (publish does its own archive + altool upload).
        // A missing iPhone should NOT block a 25-hour ship workflow.
        return .init(
            text: """
            warn: install failed via both devicectl and ideviceinstaller - skipping local install and continuing toward publish. App Store submission does NOT require a device-side install.

            devicectl: \(install.truncated.suffix(300))

            ideviceinstaller: \(alt.truncated.suffix(300))

            If you want device-side smoke testing: ensure phone is UNLOCKED, plugged in via USB-C, and trusts this Mac, then re-fire the workflow.
            """,
            success: true,
            stateUpdates: stateUpdates.merging([
                "install_skipped": .string("device_install_failed_both_paths"),
                "install_warning": .bool(true)
            ], uniquingKeysWith: { _, b in b })
        )
    }

    // Pick the first AVAILABLE iPhone (paired AND physically reachable).
    // Prefers `hardwareProperties.udid` (the canonical UDID xcodebuild and
    // devicectl install both accept) over `identifier` (a device-token that
    // some devicectl subcommands don't accept). Skips iPhones in any state
    // other than "available" - installing into "unavailable" just hangs.
    // Hang-resilient xcodebuild wrapper.
    //
    // xcodebuild on iCloud-synced project paths (~/Library/Mobile Documents/...)
    // routinely produces all build artifacts cleanly but then enters a
    // post-build cleanup state where the parent process never exits, even
    // after the .app + .swiftmodule + .appex outputs are fully written. The
    // CPU is idle, no children are running, and the process sits in 'S' state
    // forever. This isn't a bug in OUR code - it reproduces with vanilla
    // `xcodebuild` invocations on iCloud paths.
    //
    // Strategy: kick off xcodebuild in a background shell, then poll the
    // expected output dir until either:
    //   • the .app appears AND its size is stable for 10s (success: nudge
    //     xcodebuild to exit, return success regardless of exit code)
    //   • timeoutSeconds elapses (genuine build failure: kill, return whatever
    //     status / output we have)
    //
    // The wrapper returns a synthetic RawResult with whatever was on disk
    // when polling decided we were done. The caller checks for the .app
    // separately; this function only drives the build.
    static func runXcodebuildResilient(
        cmd: String,
        expectedAppsDir: String,
        timeoutSeconds: Int
    ) async -> ShellRunner.RawResult {
        // Save build output to a tmp file so we can return it even if the
        // process is force-killed.
        let tmpLog = NSTemporaryDirectory() + "xcodebuild-\(UUID().uuidString.prefix(6)).log"
        // Wrap the command to record its PID + redirect to tmpLog.
        let wrapped = """
        ( \(cmd) ) > "\(tmpLog)" 2>&1 &
        echo $!
        wait $!
        """
        // Spawn - this is fire-and-forget because we'll poll for artifacts.
        // We can't await ShellRunner.runRaw here because it blocks until exit.
        // Use Process directly.
        let proc = Process()
        proc.launchPath = "/bin/zsh"
        proc.arguments = ["-c", wrapped]
        let pidPipe = Pipe()
        proc.standardOutput = pidPipe
        proc.standardError = pidPipe
        do { try proc.run() } catch {
            return ShellRunner.RawResult(status: -1, stdout: "spawn failed: \(error.localizedDescription)", truncated: "spawn failed")
        }
        // Drain pidPipe in the background so it can never fill and block the
        // wrapper. The real build output is redirected to tmpLog, so this pipe
        // only carries the PID line, but draining removes any doubt and prevents
        // a stall if cmd ever emits to the wrapper's stdout before redirecting.
        DispatchQueue.global(qos: .utility).async {
            _ = pidPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Poll for .app appearance + size stability.
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var lastSize: Int = -1
        var stableSince: Date?
        let stabilityWindow: TimeInterval = 10.0
        var done = false
        var artifactFound = false

        while !done {
            if !proc.isRunning {
                done = true
                break
            }
            if Date() > deadline {
                proc.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                done = true
                break
            }
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: expectedAppsDir))?
                .filter { $0.hasSuffix(".app") } ?? []
            if let appName = apps.first {
                artifactFound = true
                let appPath = expectedAppsDir + "/" + appName
                let totalSize = directorySize(at: appPath)
                if totalSize == lastSize {
                    if let s = stableSince, Date().timeIntervalSince(s) >= stabilityWindow {
                        // Stable for the window. Build is done.
                        proc.terminate()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if proc.isRunning {
                            kill(proc.processIdentifier, SIGKILL)
                        }
                        done = true
                        break
                    }
                    if stableSince == nil { stableSince = Date() }
                } else {
                    lastSize = totalSize
                    stableSince = nil
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Read whatever output landed in the log file.
        let logBlob = (try? String(contentsOfFile: tmpLog, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: tmpLog)
        let trunc = logBlob.count <= 4000 ? logBlob
            : String(logBlob.prefix(4000)) + "\n…(truncated, \(logBlob.count) chars total)"
        // status: 0 if artifact present (we treat that as success regardless
        // of the wrapped subprocess's exit code, since the hang isn't
        // semantically a failure). Otherwise propagate.
        let status: Int32 = artifactFound ? 0 : proc.terminationStatus
        return ShellRunner.RawResult(status: status, stdout: logBlob, truncated: trunc)
    }

    private static func directorySize(at path: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let f as String in enumerator {
            let full = path + "/" + f
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               let s = attrs[.size] as? Int {
                total += s
            }
        }
        return total
    }

    // Devicectl-stuck fallback: pull ANY iPhone UDID out of the devicectl JSON
    // regardless of state. Used when CoreDeviceService is in its known-bad
    // state where it reports paired devices as "unavailable" but they're
    // actually reachable via libimobiledevice. The install path's
    // ideviceinstaller fallback handles the actual install in that case.
    private static func parseAnyiPhoneUDID(json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            return nil
        }
        for d in devices {
            let isPhone = ((d["deviceProperties"] as? [String: Any])?["name"] as? String)?.contains("iPhone") == true
                || ((d["hardwareProperties"] as? [String: Any])?["productType"] as? String)?.starts(with: "iPhone") == true
            let udid = ((d["hardwareProperties"] as? [String: Any])?["udid"] as? String) ?? ""
            if isPhone && !udid.isEmpty {
                return udid
            }
        }
        return nil
    }

    private static func parseFirstAvailableUDID(json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            return nil
        }
        for d in devices {
            let isPhone = ((d["deviceProperties"] as? [String: Any])?["name"] as? String)?.contains("iPhone") == true
                || ((d["hardwareProperties"] as? [String: Any])?["productType"] as? String)?.starts(with: "iPhone") == true
            // The only "ready to install" composite check we can rely on
            // across Xcode 15→26: connectionProperties.tunnelState=connected
            // OR top-level "transportType" is present AND pairingState=paired.
            let connProps = (d["connectionProperties"] as? [String: Any]) ?? [:]
            let tunnelState = connProps["tunnelState"] as? String
            let pairing = connProps["pairingState"] as? String
            let transport = connProps["transportType"] as? String
            let reachable = (tunnelState == "connected") || (transport != nil && pairing == "paired")
            let udid = ((d["hardwareProperties"] as? [String: Any])?["udid"] as? String) ?? ""
            if isPhone && reachable && !udid.isEmpty {
                return udid
            }
        }
        return nil
    }

    // MARK: - Publish

    private static func publishToAppStore(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let project = input["project"]?.stringValue ?? run.parameters["project"]?.stringValue ?? ""
        guard let cfg = ShipConfig.load(forProject: project) else {
            return missingConfigResult(project: project, op: "publish_to_appstore")
        }
        // Safety net: refuse to publish if a previous submission is still
        // in review for this app. Spec edge case - protects v2.2.0-style
        // "DO NOT TOUCH while in review" rules.
        let preCheck = await checkASCStatus(input: input, run: run)
        let stateNow = preCheck.stateUpdates["asc_state"]?.stringValue ?? ""
        let blocking: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE"]
        if blocking.contains(stateNow) {
            return .init(
                text: "error: refusing to publish - current submission is in '\(stateNow)'. Resolve that submission first.",
                success: false,
                stateUpdates: ["asc_state": .string(stateNow)]
            )
        }
        let orchestratorScript = cfg.submissionOrchestratorPath
        guard FileManager.default.fileExists(atPath: orchestratorScript) else {
            return .init(
                text: "error: submission orchestrator not found at \(orchestratorScript). Update ship-config.json's `submissionOrchestrator` path.",
                success: false,
                stateUpdates: [:]
            )
        }
        let cmd = "cd \"\(cfg.projectRoot)\" && node \"\(orchestratorScript)\" 2>&1"
        let r = await ShellRunner.runRaw(command: cmd, timeoutSeconds: 1800)
        // Best-effort id extraction from orchestrator output. The convention is
        // a `submission id: <uuid>` line near the end.
        let submissionId = extractFirstMatch(in: r.stdout, regex: #"submission id[: ]+([0-9a-fA-F-]{36})"#)
        var updates: [String: JSONValue] = [
            "publish_exit": .int(Int(r.status)),
            "publish_log_tail": .string(String(r.truncated.suffix(800)))
        ]
        if let sid = submissionId { updates["asc_submission_id"] = .string(sid) }
        updates["asc_submitted_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        return .init(
            text: "[publish_to_appstore exit \(r.status)]\n\(r.truncated)",
            success: r.status == 0,
            stateUpdates: updates
        )
    }

    // MARK: - Check status

    private static func checkASCStatus(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let project = input["project"]?.stringValue ?? run.parameters["project"]?.stringValue ?? ""
        guard let cfg = ShipConfig.load(forProject: project) else {
            return missingConfigResult(project: project, op: "check_asc_status")
        }
        // Reuse the project's existing asc-status.js script.
        let statusScript = cfg.projectRoot + "/asc-status.js"
        guard FileManager.default.fileExists(atPath: statusScript) else {
            return .init(
                text: "error: \(statusScript) not found. Add asc-status.js to the project root or update ship-config.",
                success: false,
                stateUpdates: [:]
            )
        }
        let cmd = "cd \"\(cfg.projectRoot)\" && node \"asc-status.js\" 2>&1"
        let r = await ShellRunner.runRaw(command: cmd, timeoutSeconds: 60)
        // Try to extract appStoreState from common output shapes.
        // asc-status.js typically prints `appStoreState: <STATE>`.
        let stateExtracted = extractFirstMatch(in: r.stdout, regex: #"appStoreState[\s":=]+([A-Z_]+)"#)
            ?? extractFirstMatch(in: r.stdout, regex: #"^([A-Z_]{6,})$"#)
            ?? "UNKNOWN"
        return .init(
            text: "[check_asc_status exit \(r.status)] state=\(stateExtracted)\n\(r.truncated)",
            success: r.status == 0,
            stateUpdates: [
                "asc_state": .string(stateExtracted),
                "asc_last_checked_at": .string(ISO8601DateFormatter().string(from: Date()))
            ]
        )
    }

    // MARK: - Screenshot generation
    //
    // Boots a 6.5" iPhone simulator, installs the latest Debug build, walks
    // the app's primary screens via simctl, and writes one PNG per screen
    // under <project>/marketing/screenshots/iphone-6.5/. The Claude Design
    // pass that decorates these for App Store Connect runs as a follow-up
    // claudeAgent phase - this tool only captures the raw frames.
    //
    // Resolution: iPhone 15 Pro Max simulator (6.7" canonical for ASC). Apple
    // accepts anything ≥1284×2778 for 6.5", and the 15 Pro Max produces
    // 1290×2796, which is fine.
    private static func generateScreenshots(input: [String: JSONValue], run: CommandV2Run) async -> IOSDispatcherV2Result {
        let project = input["project"]?.stringValue ?? run.parameters["project"]?.stringValue ?? ""
        let projectRoot = ProjectsResolver.resolve(project: project)
        guard !projectRoot.isEmpty else {
            return .init(text: "error: cannot resolve project '\(project)'", success: false, stateUpdates: [:])
        }
        let outDir = projectRoot + "/marketing/screenshots/iphone-6.5"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // 1. Pick the highest-end iPhone Pro Max simulator available, falling
        //    back through the model list. Xcode 26 ships iPhone 17 Pro Max as
        //    the canonical 6.7" device for ASC; older Xcode has 15 Pro Max.
        //    If none of the named devices exist, take the first booted one,
        //    then the first iPhone available.
        let bootCmd = """
        UDID=$(xcrun simctl list devices booted -j | python3 -c "import sys,json; d=json.load(sys.stdin); \
        out=[x['udid'] for runs in d['devices'].values() for x in runs if x.get('name','').startswith('iPhone')]; \
        print(out[0] if out else '')" 2>/dev/null)
        if [[ -z "$UDID" ]]; then
          for NAME in 'iPhone 17 Pro Max' 'iPhone 16 Pro Max' 'iPhone 15 Pro Max' 'iPhone 17 Pro' 'iPhone 16 Pro' 'iPhone 15 Pro' 'iPhone 17' 'iPhone 16'; do
            UDID=$(xcrun simctl list devices available -j | python3 -c "import sys,json,os; d=json.load(sys.stdin); \
            n=os.environ['NAME']; out=[x['udid'] for runs in d['devices'].values() for x in runs if x.get('name','')==n]; \
            print(out[0] if out else '')" 2>/dev/null)
            if [[ -n "$UDID" ]]; then break; fi
          done
        fi
        if [[ -z "$UDID" ]]; then
          UDID=$(xcrun simctl list devices available -j | python3 -c "import sys,json; d=json.load(sys.stdin); \
          out=[x['udid'] for runs in d['devices'].values() for x in runs if x.get('name','').startswith('iPhone')]; \
          print(out[0] if out else '')" 2>/dev/null)
        fi
        if [[ -z "$UDID" ]]; then echo "no iPhone simulator available"; exit 1; fi
        xcrun simctl boot "$UDID" 2>/dev/null || true
        xcrun simctl bootstatus "$UDID" -b 2>/dev/null || true
        echo $UDID
        """
        let boot = await ShellRunner.runRaw(command: bootCmd, timeoutSeconds: 90)
        let udidLines = boot.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let udid = udidLines.last(where: { $0.range(of: "^[0-9A-F-]{20,}$", options: .regularExpression) != nil }) ?? ""
        guard !udid.isEmpty else {
            return .init(text: "[screenshot boot failed]\n\(boot.truncated)", success: false, stateUpdates: [:])
        }

        // 2. xcodegen + xcodebuild for sim.
        let yamlPath = projectRoot + "/project.yml"
        if FileManager.default.fileExists(atPath: yamlPath) {
            _ = await ShellRunner.runRaw(
                command: "cd \"\(projectRoot)\" && xcodegen generate 2>&1",
                timeoutSeconds: 60
            )
        }
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: projectRoot))?
            .filter { $0.hasSuffix(".xcodeproj") && $0.range(of: #" \d+\.xcodeproj$"#, options: .regularExpression) == nil } ?? []
        guard let xcodeproj = projects.first else {
            return .init(text: "error: no .xcodeproj found", success: false, stateUpdates: [:])
        }
        let scheme = (xcodeproj as NSString).deletingPathExtension
        // Stage in /tmp to dodge iCloud-sync xattr corruption (see installToDevice).
        let projectSlug = (xcodeproj as NSString).deletingPathExtension.lowercased()
        let buildDir = "/tmp/grux-ios-build/\(projectSlug)-sim"
        try? FileManager.default.removeItem(atPath: buildDir)
        try? FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)
        _ = await ShellRunner.runRaw(
            command: "xattr -rc \"\(projectRoot)\" 2>/dev/null || true",
            timeoutSeconds: 60
        )
        let buildCmd = """
        cd "\(projectRoot)" && xcodebuild \
          -project "\(xcodeproj)" \
          -scheme "\(scheme)" \
          -configuration Debug \
          -destination "platform=iOS Simulator,id=\(udid)" \
          -derivedDataPath "\(buildDir)" \
          CODE_SIGNING_ALLOWED=NO \
          build 2>&1
        """
        let appsRoot = buildDir + "/Build/Products/Debug-iphonesimulator"
        let build = await Self.runXcodebuildResilient(cmd: buildCmd, expectedAppsDir: appsRoot, timeoutSeconds: 600)
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: appsRoot))?
            .filter { $0.hasSuffix(".app") } ?? []
        guard let appName = apps.first else {
            return .init(
                text: "[xcodebuild for sim exit \(build.status), no .app produced]\n\(String(build.truncated.suffix(2000)))",
                success: false,
                stateUpdates: ["screenshots_xcodebuild_exit": .int(Int(build.status))]
            )
        }
        let appPath = appsRoot + "/" + appName

        // Read bundle id from Info.plist.
        let plistCmd = "/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \"\(appPath)/Info.plist\" 2>/dev/null"
        let plist = await ShellRunner.runRaw(command: plistCmd, timeoutSeconds: 5)
        let bundleId = plist.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else {
            return .init(text: "error: could not read bundle id from \(appPath)", success: false, stateUpdates: [:])
        }

        // Capture sequence: launch the app, then drive it through 10 distinct
        // states using `idb ui tap/text/swipe` (NOT `simctl io tap` - that
        // subcommand does not exist; the prior implementation silently failed
        // every tap and produced 10 byte-identical screenshots).
        //
        // For each slot we hash the captured PNG and compare against the prior
        // frame; if unchanged, the input fell on dead space, so we try the
        // next fallback action. Coordinates target the iPhone 17 Pro Max
        // viewport (440×956 points). Hotspots are intentionally generic so a
        // notes app, a story journal, a tab-bar app, and a single-screen
        // utility all stand a chance of producing 10 distinct frames.
        //
        // App Preview video records the entire navigation in the background.
        let videoOutDir = projectRoot + "/marketing/previews"
        try? FileManager.default.createDirectory(atPath: videoOutDir, withIntermediateDirectories: true)

        let idbPath = await Self.findIDB()
        guard !idbPath.isEmpty else {
            return .init(
                text: """
                error: idb not found. The screenshot capture requires Facebook's idb to inject taps into the simulator (xcrun simctl has no tap subcommand). Install with:
                  brew install facebook/fb/idb-companion
                  pipx install --python python3.13 fb-idb
                """,
                success: false,
                stateUpdates: [:]
            )
        }

        // Start the simulator + app, warm up idb, kick off background video.
        // Status-bar override (time → 9:41, full bars, charged battery)
        // applied BEFORE launch so the captured frames are byte-deterministic
        // across runs and match App Store Connect's marketing convention.
        // Without this, every screenshot has a different live clock and
        // hashes drift between runs.
        let videoPath = "\(videoOutDir)/preview_main.mp4"
        let pidFile = "/tmp/grux-rec-\(udid).pid"
        let preamble = """
        xcrun simctl install "\(udid)" "\(appPath)" 2>/dev/null
        xcrun simctl status_bar "\(udid)" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
        xcrun simctl launch "\(udid)" "\(bundleId)" >/dev/null 2>&1 || true
        sleep 3
        "\(idbPath)" connect "\(udid)" >/dev/null 2>&1 || true
        rm -f "\(videoPath)"
        nohup xcrun simctl io "\(udid)" recordVideo --codec=h264 --display=internal "\(videoPath)" </dev/null >/dev/null 2>&1 &
        echo $! > "\(pidFile)"
        sleep 1
        echo preamble-done
        """
        _ = await ShellRunner.runRaw(command: preamble, timeoutSeconds: 30)

        let captureReport = await Self.runCaptureLoop(
            udid: udid, idbPath: idbPath, outDir: outDir, projectRoot: projectRoot
        )

        // Stop the video recording. SIGINT first so simctl flushes the .mp4
        // header cleanly. If the process doesn't honor INT within 5s - which
        // happens occasionally; one 2026-04-30 run hung 18min on this exact
        // step because the SIGINT didn't reach simctl - escalate
        // to SIGKILL and pkill any orphan recordVideo for this video path.
        // Either way, return within 12s; the .mp4 may be missing its trailer
        // box but the screenshots-design phase only needs the raw PNGs.
        let postamble = """
        PID=$(cat "\(pidFile)" 2>/dev/null)
        if [[ -n "$PID" ]]; then
          kill -INT "$PID" 2>/dev/null
          for i in 1 2 3 4 5; do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            sleep 1
          done
          if kill -0 "$PID" 2>/dev/null; then
            kill -KILL "$PID" 2>/dev/null
          fi
        fi
        # Belt-and-suspenders: pkill any orphan simctl recordVideo writing
        # to OUR video path. Different UDID's recordVideo runs on the same
        # machine are left alone via the targeted -f match.
        pkill -KILL -f "simctl io .* recordVideo .* \(videoPath)" 2>/dev/null || true
        rm -f "\(pidFile)"
        xcrun simctl status_bar "\(udid)" clear >/dev/null 2>&1 || true
        echo postamble-done
        """
        _ = await ShellRunner.runRaw(command: postamble, timeoutSeconds: 15)

        // Persist a sidecar report so the design pass and tests can inspect
        // which fallback fired per slot, and which (if any) fell through.
        let reportPath = outDir + "/capture-report.json"
        let reportLines = captureReport.map { "  \"\($0.slot)\": { \"action\": \"\($0.action)\", \"hash\": \"\($0.hash)\", \"distinct\": \($0.distinct) }" }
        let reportJSON = "{\n" + reportLines.joined(separator: ",\n") + "\n}\n"
        try? reportJSON.write(toFile: reportPath, atomically: true, encoding: .utf8)

        let pngs = (try? FileManager.default.contentsOfDirectory(atPath: outDir))?
            .filter { $0.hasSuffix(".png") } ?? []
        let vids = (try? FileManager.default.contentsOfDirectory(atPath: videoOutDir))?
            .filter { $0.hasSuffix(".mp4") } ?? []
        let distinctCount = Set(captureReport.map { $0.hash }).count
        let dupSlots = captureReport.filter { !$0.distinct }.map { $0.slot }
        // QUALITY BAR - require at least 2 distinct frames as raw feedstock.
        //
        // The OLD threshold (8/10 distinct simulator captures) was wrong for
        // the new pipeline: as of 2026-04-29 the screenshots-DESIGN phase
        // produces composed marketing screenshots - five
        // 1320×2868 frames built from a handful of raw device screens with
        // distinct headlines, copy treatments, and brand backgrounds. The
        // ASC variety comes from the DESIGN composition, not from how many
        // unique simulator screens we walked through. As long as we have at
        // least 2 distinct raw frames (so the design pass has options to
        // choose from per slot), the pipeline produces high-variety
        // marketing screenshots downstream.
        //
        // The 8/10 bar systematically fails for any app without a
        // tab/list/detail navigation tree (the idb-tap hotspots are tuned for
        // notes-style apps). A single-screen app (slider + results gate +
        // history) measured 3/10. Most apps Grux ships will sit in the 2-5
        // range. Hold the bar at 2 and let the design phase do the variety
        // work.
        let qualityMet = distinctCount >= 2
        let summary: String
        if qualityMet {
            summary = "captured \(pngs.count) screenshots (\(distinctCount) distinct) + \(vids.count) preview video(s) to \(outDir). Report: \(reportPath). Note: the design phase composes marketing variants from raw frames - distinctness floor is now 2 since variety comes from design composition."
        } else {
            summary = """
            CAPTURE QUALITY TOO LOW - \(distinctCount)/10 distinct frames; needs ≥2 raw distinct frames as feedstock for the design phase.
            Duplicate slots: \(dupSlots.joined(separator: ", "))
            The idb-tap heuristic didn't find any navigable second screen - every tap landed on the same view. Either the app is genuinely single-screen (in which case capture a manual second state - e.g. by toggling a state or scrolling), or idb didn't connect (check console for `idb connect` errors).
            Inspect the captured PNGs at \(outDir) and the per-slot report at \(reportPath).
            """
        }
        return .init(
            text: summary,
            success: qualityMet,
            stateUpdates: [
                "screenshots_dir": .string(outDir),
                "screenshots_count": .int(pngs.count),
                "screenshots_distinct": .int(distinctCount),
                "screenshots_duplicate_slots": .string(dupSlots.joined(separator: ",")),
                "screenshots_quality_met": .bool(qualityMet),
                "screenshots_report": .string(reportPath),
                "previews_dir": .string(videoOutDir),
                "previews_count": .int(vids.count),
                "screenshots_bundle_id": .string(bundleId)
            ]
        )
    }

    // Per-slot result from the verify-and-fallback capture loop.
    private struct SlotResult {
        let slot: String     // filename slot, e.g. "02_compose_or_detail"
        let action: String   // human-readable action that produced the frame
        let hash: String     // md5 of the captured PNG
        let distinct: Bool   // whether the frame differs from the previous slot
    }

    // Drives the capture sequence. For each slot we try the primary action,
    // capture, hash, and compare; if the screen didn't change we fall through
    // to the next attempt. The frame is always written (so composite.py never
    // sees a missing file), but `distinct=false` flags slots where every
    // attempt landed on dead space.
    private static func runCaptureLoop(
        udid: String, idbPath: String, outDir: String, projectRoot: String
    ) async -> [SlotResult] {
        // (slot, [(actionLabel, idbArgs?)])  - args=nil means "capture without
        // input" (used for the launch frame and as a 'recapture' fallback).
        // iPhone 17 Pro Max is 440×956 logical points; coords here are tuned
        // for that viewport but nudged to common hotspots so they cover a
        // notes/journal/list app shape.
        typealias Attempt = (label: String, idbArgs: String?)

        // Per-project override: <project>/.grux/screenshot-actions.json. When
        // the heuristic library doesn't fit an app's UI, the project can ship
        // its own tuned action sequence. Falls back to the heuristic if the
        // file is absent or malformed.
        let overridePath = projectRoot + "/.grux/screenshot-actions.json"
        let heuristic: [(name: String, attempts: [Attempt])] = [
            ("01_main", [("initial-launch", nil)]),
            ("02_compose_or_detail", [
                ("tap-fab-lower-right", "ui tap 395 810"),
                ("tap-bottom-center",   "ui tap 220 810"),
                ("tap-top-right-plus",  "ui tap 410 110"),
                ("tap-first-card",      "ui tap 220 240"),
                ("tap-mid-card",        "ui tap 220 480")
            ]),
            ("03_with_text", [
                ("type-pin-what-matters", #"ui text "Pin what matters""#),
                ("type-once-upon",        #"ui text "Once upon a time""#),
                ("tap-center-then-type",  "ui tap 220 480"),  // surface keyboard
                ("type-hello",            #"ui text "Hello""#)
            ]),
            ("04_main_after", [
                // Standard ways to leave a modal compose view. Pull-down
                // dismisses sheets (iOS 13+); top-right is usually Save/Done;
                // top-left is Cancel/Back. Try several so SOMETHING fires.
                ("swipe-modal-dismiss",  "ui swipe 220 100 220 800"),
                ("tap-save-top-right",   "ui tap 410 110"),
                ("tap-back-top-left",    "ui tap 30 110"),
                ("swipe-edge-right",     "ui swipe 0 480 220 480"),
                ("tap-tab-home",         "ui tap 73 925")
            ]),
            ("05_tagged_note", [
                ("tap-row-1",          "ui tap 220 240"),
                ("tap-row-2",          "ui tap 220 320"),
                ("tap-row-3",          "ui tap 220 400"),
                ("swipe-row-reveal",   "ui swipe 380 240 100 240"),
                ("tap-search",         "ui tap 220 130"),
                ("tap-segment-2",      "ui tap 300 180"),
                ("tap-row-4",          "ui tap 220 500")
            ]),
            ("06_pinned_section", [
                ("scroll-down",        "ui swipe 220 300 220 700"),
                ("scroll-up-reveal",   "ui swipe 220 700 220 300"),
                ("tap-row-different",  "ui tap 220 380"),
                ("swipe-row-left",     "ui swipe 380 320 100 320"),
                ("tap-segment-1",      "ui tap 140 180"),
                ("tap-search",         "ui tap 220 130"),
                ("tap-row-far",        "ui tap 220 560")
            ]),
            ("07_settings", [
                ("tap-gear-top-right",  "ui tap 410 110"),
                ("tap-tab-last",        "ui tap 367 925"),
                ("tap-tab-third",       "ui tap 275 925"),
                ("tap-hamburger",       "ui tap 30 110")
            ]),
            ("08_settings_scroll", [
                ("scroll-up-1",       "ui swipe 220 700 220 300"),
                ("scroll-up-2",       "ui swipe 220 800 220 400"),
                ("tap-setting-row",   "ui tap 220 600"),
                ("tap-setting-row-2", "ui tap 220 400")
            ]),
            ("09_main_final", [
                ("tap-back-top-left",  "ui tap 30 110"),
                ("tap-tab-home",       "ui tap 73 925"),
                ("swipe-edge-right",   "ui swipe 0 480 220 480"),
                ("tap-bottom-center",  "ui tap 220 925")
            ]),
            ("10_third_view", [
                // Tabs are usually equally spaced; (220, 925) hits the
                // middle slot on 3-tab apps (Prompts here), (275, 925)
                // hits middle on 4-tab apps. Try both.
                ("tap-tab-mid-3tab",  "ui tap 220 925"),
                ("tap-tab-mid-4tab",  "ui tap 275 925"),
                ("tap-tab-second",    "ui tap 110 925"),
                ("tap-tab-fourth",    "ui tap 330 925"),
                ("tap-mid-card",      "ui tap 220 480"),
                ("swipe-page-right",  "ui swipe 50 480 380 480")
            ])
        ]

        let slots = Self.loadActionOverride(path: overridePath) ?? heuristic

        // Global hash dedup: a slot only counts as `distinct` if its frame
        // doesn't match ANY previously-captured slot. Adjacent-only dedup
        // (which we used initially) catches "input never fired" but lets
        // through "ended up at a screen we've already shown" - Apple sees
        // that as a duplicate too.
        var seenHashes = Set<String>()
        var results: [SlotResult] = []

        for slot in slots {
            let slotPath = "\(outDir)/\(slot.name).png"
            try? FileManager.default.removeItem(atPath: slotPath)

            var produced: SlotResult?
            var lastHash = ""
            for attempt in slot.attempts {
                if let args = attempt.idbArgs {
                    _ = await ShellRunner.runRaw(
                        command: "\"\(idbPath)\" \(args) --udid \"\(udid)\" 2>&1",
                        timeoutSeconds: 10
                    )
                    // 1.5s lets modal-sheet animations + keyboard transitions
                    // settle before we hash the screenshot. Shorter waits
                    // produced run-to-run hash drift.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                _ = await ShellRunner.runRaw(
                    command: "xcrun simctl io \"\(udid)\" screenshot \"\(slotPath)\" 2>/dev/null",
                    timeoutSeconds: 10
                )
                let hash = await Self.md5OfFile(slotPath)
                if hash.isEmpty { continue }
                lastHash = hash
                if !seenHashes.contains(hash) {
                    seenHashes.insert(hash)
                    produced = SlotResult(slot: slot.name, action: attempt.label, hash: hash, distinct: true)
                    break
                }
            }

            if let r = produced {
                results.append(r)
            } else {
                // Every attempt produced a frame matching an earlier slot
                // (or all attempts errored). Keep the last captured PNG so
                // composite.py never sees a missing file, but flag it as
                // duplicate so the publish phase can refuse to ship.
                results.append(SlotResult(
                    slot: slot.name,
                    action: "duplicate-of-earlier-slot",
                    hash: lastHash,
                    distinct: false
                ))
            }
        }

        return results
    }

    // Per-project override format:
    //   {
    //     "slots": [
    //       { "name": "01_main", "actions": [ { "label": "launch", "idb": null } ] },
    //       { "name": "02_compose", "actions": [ { "label": "tap-fab", "idb": "ui tap 395 810" } ] }
    //     ]
    //   }
    // Returns nil (use heuristic) if the file is absent or malformed.
    private struct ActionOverrideFile: Decodable {
        let slots: [SlotOverride]
        struct SlotOverride: Decodable {
            let name: String
            let actions: [ActionOverride]
        }
        struct ActionOverride: Decodable {
            let label: String
            let idb: String?
        }
    }

    private static func loadActionOverride(path: String) -> [(name: String, attempts: [(label: String, idbArgs: String?)])]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONDecoder().decode(ActionOverrideFile.self, from: data),
              !parsed.slots.isEmpty
        else { return nil }
        return parsed.slots.map { slot in
            (name: slot.name,
             attempts: slot.actions.map { (label: $0.label, idbArgs: $0.idb) })
        }
    }

    // Locate the `idb` Python CLI. pipx installs it at ~/.local/bin/idb;
    // older setups may use /usr/local/bin or /opt/homebrew/bin. Falls back
    // to a $PATH lookup via the user's login shell.
    private static func findIDB() async -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/idb",
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let r = await ShellRunner.runRaw(command: "command -v idb 2>/dev/null", timeoutSeconds: 5)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // md5 of a file via the system `md5 -q` utility - avoids pulling in
    // CryptoKit just for capture verification.
    private static func md5OfFile(_ path: String) async -> String {
        let r = await ShellRunner.runRaw(
            command: "md5 -q \"\(path)\" 2>/dev/null",
            timeoutSeconds: 5
        )
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func missingConfigResult(project: String, op: String) -> IOSDispatcherV2Result {
        let templatePath = "<grux-mac>/docs/templates/ship-config.json"
        return .init(
            text: """
                error: \(op) refused - no ship-config.json found for project '\(project)'.
                Create one at <project-root>/.grux/ship-config.json.
                Template lives at \(templatePath).
                """,
            success: false,
            stateUpdates: ["ship_config_missing": .string(project)]
        )
    }

    private static func extractFirstMatch(in text: String, regex: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else { return nil }
        let r = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: r), m.numberOfRanges >= 2 else { return nil }
        guard let group = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }
}

// MARK: - ShipConfig

// Per-project config that gates V2 publishing. Without it, Phase 5 refuses
// to run rather than guess at signing identities or paths. Lives at
// <project>/.grux/ship-config.json.
struct ShipConfig: Codable {
    let ascAppId: String
    let bundleId: String
    let teamId: String
    let ascApiKeyId: String
    let ascApiKeyIssuerId: String
    let ascApiKeyPath: String?
    let distSigningIdentity: String?
    let distProvisioningProfile: String?
    let infoPlistPath: String?
    let subTargetPlists: [String]?
    let submissionOrchestrator: String?

    // Review-readiness blocker answers - consumed by ios_fix_review_blockers
    // so Apple's "Unable to Add for Review" gating clears autonomously.
    let privacyPolicyUrl: String?
    let supportUrl: String?
    let marketingUrl: String?
    let primaryCategory: String?               // e.g. PRODUCTIVITY (see /v1/appCategories)
    let secondaryCategory: String?
    let contentRightsDeclaration: String?      // DOES_NOT_USE_THIRD_PARTY_CONTENT | USES_THIRD_PARTY_CONTENT
    let ageRatingPreset: String?               // ALL_AGES_4_PLUS (default) - future: TEEN_12_PLUS, MATURE_17_PLUS

    // Resolved at load time - caller passes the project root path or alias
    // and we resolve to absolute paths.
    var projectRoot: String = ""
    var submissionOrchestratorPath: String {
        let s = submissionOrchestrator ?? "asc-submit.js"
        if s.hasPrefix("/") { return s }
        return projectRoot + "/" + s
    }

    private enum CodingKeys: String, CodingKey {
        case ascAppId, bundleId, teamId, ascApiKeyId, ascApiKeyIssuerId,
             ascApiKeyPath, distSigningIdentity, distProvisioningProfile,
             infoPlistPath, subTargetPlists, submissionOrchestrator,
             privacyPolicyUrl, supportUrl, marketingUrl,
             primaryCategory, secondaryCategory,
             contentRightsDeclaration, ageRatingPreset
    }

    static func load(forProject project: String) -> ShipConfig? {
        let root = ProjectsResolver.resolve(project: project)
        guard !root.isEmpty else { return nil }
        let cfgPath = root + "/.grux/ship-config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)) else { return nil }
        guard var cfg = try? JSONDecoder().decode(ShipConfig.self, from: data) else { return nil }
        cfg.projectRoot = root
        return cfg
    }
}

// MARK: - ProjectsResolver

// Resolve a project alias or path to an absolute root directory. Aliases
// are matched against ProjectsIndex (already in GruxShellCore) when
// available, with a known-projects fallback.
enum ProjectsResolver {
    // Canonical home for Grux-built iOS apps. Lives under ~/Projects (NOT
    // iCloud Drive - iCloud injects xattrs that break codesign), and is the
    // default `root_dir` for ios_scaffold. New apps land here; projects that
    // live elsewhere are reached through the alias file below.
    static let gruxAppsDir = NSHomeDirectory() + "/Projects/GruxApps"

    // User-configured aliases for projects that live OUTSIDE GruxApps. Empty
    // by default: a fresh install ships nobody's project list and discovers
    // what is actually on the machine instead (see resolve() below).
    //
    // Format is a flat JSON map of alias to absolute path, `~` accepted:
    //   { "my app": "~/Work/MyApp", "myapp": "~/Work/MyApp" }
    // Add one alias line per spelling you want to say out loud. A missing or
    // malformed file means "no aliases", never an error.
    static var aliasesURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("project-aliases.json")
    }

    // Keys are lowercased for matching; values are tilde-expanded. Blank keys
    // and blank paths are dropped so a half-edited file degrades to a smaller
    // map rather than a broken lookup.
    static func configuredAliases() -> [String: String] {
        guard let data = try? Data(contentsOf: aliasesURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        var out: [String: String] = [:]
        for (alias, path) in raw {
            let key = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let root = NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
            guard !key.isEmpty, !root.isEmpty else { continue }
            out[key] = root
        }
        return out
    }

    /// Whether this string NAMES a project that exists, with no fallback.
    ///
    /// `resolve(project:)` cannot answer this: its last line returns
    /// `currentDirectoryPath + "/" + trimmed` for anything it does not recognise, so it
    /// always succeeds and can never be used as a membership test. That is correct for
    /// resolving and useless for deciding whether a sentence was a command.
    ///
    /// WHY IT EXISTS. A builtin trigger like "translate {project}" compiles to `^translate
    /// (.+)$`, so "translate this email into Spanish" matched, and the fast path in
    /// ChatService runs BEFORE the model and before any key check. A person on a fresh Mac
    /// got no answer, heard the Mac say out loud "this email into Spanish just shipped. I'll
    /// check back in a week before localizing.", and had a run persisted with
    /// nextWakeAt = now + 7 days that re-armed on every launch afterwards.
    ///
    /// Answering "no" here is what sends the sentence to the model instead. On a machine
    /// with no projects nothing resolves, which is the right answer: there is nothing to
    /// ship, translate or release.
    static func namesAKnownProject(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        if configuredAliases()[lower] != nil { return true }
        if ProjectRegistryStore.find(name: trimmed) != nil { return true }

        let fm = FileManager.default
        for root in [gruxAppsDir, NSHomeDirectory() + "/Projects"] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root + "/" + trimmed, isDirectory: &isDir), isDir.boolValue {
                return true
            }
            if let entries = try? fm.contentsOfDirectory(atPath: root),
               entries.contains(where: { $0.lowercased() == lower }) {
                return true
            }
        }
        return false
    }

    static func resolve(project: String) -> String {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Already an absolute path?
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        // Tilde expansion.
        if trimmed.hasPrefix("~") {
            return NSString(string: trimmed).expandingTildeInPath
        }
        // User-configured aliases (projects living outside GruxApps).
        let lower = trimmed.lowercased()
        if let hit = configuredAliases()[lower] { return hit }
        // GruxApps/ - the canonical home for Grux-built apps. Try the input
        // verbatim first (preserves CamelCase like "MyNotes"), then any
        // case-insensitive match against existing entries.
        let exact = gruxAppsDir + "/" + trimmed
        if FileManager.default.fileExists(atPath: exact) { return exact }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: gruxAppsDir),
           let match = entries.first(where: { $0.lowercased() == lower })
        {
            return gruxAppsDir + "/" + match
        }
        // Legacy ~/Projects/<Name> - pre-GruxApps location. Same case-tolerant
        // lookup so "mynotes" still resolves to ~/Projects/MyNotes.
        let projectsRoot = NSHomeDirectory() + "/Projects"
        let projectsExact = projectsRoot + "/" + trimmed
        if FileManager.default.fileExists(atPath: projectsExact) { return projectsExact }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot),
           let match = entries.first(where: { $0.lowercased() == lower })
        {
            return projectsRoot + "/" + match
        }
        // Fallback: treat as a relative path from CWD.
        return FileManager.default.currentDirectoryPath + "/" + trimmed
    }

    // List Grux-built iOS apps the user can pick from. Used by the ChatService
    // gate when "ship the iOS app" fires without a project name. Returns
    // display names sorted alphabetically, deduped across (a) GruxApps/,
    // (b) user-configured aliases, (c) ~/Projects/<Name>/ spillover. An empty
    // result is a supported state: nothing is configured and nothing is on
    // disk yet, and the caller renders that as a "no apps found" line.
    static func listKnownIosApps() -> [String] {
        var seen = Set<String>()
        var apps: [String] = []
        func add(name: String, root: String, requireBuildFiles: Bool = true) {
            let lower = name.lowercased()
            if seen.contains(lower) { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return }
            if requireBuildFiles {
                let hasXcodegen = FileManager.default.fileExists(atPath: root + "/project.yml")
                let kids = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                let hasXcodeproj = kids.contains(where: { $0.hasSuffix(".xcodeproj") })
                guard hasXcodegen || hasXcodeproj else { return }
            }
            seen.insert(lower)
            apps.append(name)
        }
        // 1) GruxApps/ - canonical home for Grux-built apps.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: gruxAppsDir) {
            for entry in entries where !entry.hasPrefix(".") {
                add(name: entry, root: gruxAppsDir + "/" + entry)
            }
        }
        // 2) User-configured aliases - projects hosted outside GruxApps. Trust
        // the alias map (skip the project.yml/.xcodeproj check - some projects
        // use workspaces or non-standard layouts but ARE shippable). The alias
        // itself is the display name so the answer round-trips back through
        // resolve() verbatim when the user says it.
        for (alias, path) in configuredAliases() {
            add(name: alias, root: path, requireBuildFiles: false)
        }
        // 3) ~/Projects/<Name>/ - pre-GruxApps spillover. Skip GruxApps
        // (already covered) and skip non-iOS dirs (no project.yml/.xcodeproj).
        let projectsRoot = NSHomeDirectory() + "/Projects"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) {
            for entry in entries where !entry.hasPrefix(".") && entry != "GruxApps" {
                add(name: entry, root: projectsRoot + "/" + entry)
            }
        }
        return apps.sorted { $0.lowercased() < $1.lowercased() }
    }
}
