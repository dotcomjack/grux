import Foundation

// Built-in V2 command catalog. User-defined commands can be added at
// runtime via CommandV2Engine.register; these are the seeded ones every
// Grux install gets.
enum CommandV2Definitions {

    // MARK: - smoke-hello-world
    //
    // The forcing-function E2E test. Runs in <5 seconds, exercises:
    //   speak → setState → builtin(echo) → branch → speak → speak (done)
    // Used by SmokeTest to prove the engine boots, executes phases, mutates
    // state, evaluates branches, and reports completion. If this passes, the
    // engine substrate is healthy.
    static func smokeHelloWorld() -> CommandV2Definition {
        CommandV2Definition(
            id: "smoke-hello-world",
            displayName: "smoke: hello world",
            voiceTriggers: ["smoke v2", "v2 smoke", "test workflow"],
            description: "End-to-end smoke test of the Commands V2 engine. Speaks twice, mutates state, branches.",
            category: .system,
            parameters: [],
            phases: [
                .init(
                    id: "greet",
                    displayName: "Greet",
                    action: .speak(text: "Commands V2 smoke test starting.", audioCueAfter: nil)
                ),
                .init(
                    id: "stash",
                    displayName: "Stash a value",
                    action: .setState(key: "color", valueExpr: .literal(.string("teal")))
                ),
                .init(
                    id: "echo",
                    displayName: "Echo via builtin",
                    action: .builtin(name: "echo", args: ["text": .string("smoke world says hi")])
                ),
                .init(
                    id: "decide",
                    displayName: "Branch on state",
                    action: .branch(
                        condition: .stateEquals(key: "color", value: "teal"),
                        ifTrue: "celebrate",
                        ifFalse: "sad"
                    )
                ),
                .init(
                    id: "sad",
                    displayName: "Sad path (only reachable via false branch)",
                    action: .speak(text: "If you hear this, the branch evaluator is broken.", audioCueAfter: nil)
                ),
                .init(
                    id: "celebrate",
                    displayName: "Celebrate (took the true branch)",
                    action: .speak(
                        text: "Engine is healthy. Branch and state and speech all working.",
                        audioCueAfter: AudioCue(kind: .successChime)
                    )
                )
            ]
        )
    }

    // MARK: - check-asc-status
    //
    // One-off ASC status read for a project. No 24h wait, no celebration -
    // just speak the current appStoreState. Voice trigger: "what's the
    // status of {project}?"
    static func checkASCStatus() -> CommandV2Definition {
        CommandV2Definition(
            id: "check-asc-status",
            displayName: "check ASC status",
            voiceTriggers: [
                "what's the status of {project}",
                "check status of {project}",
                "asc status {project}"
            ],
            description: "Query App Store Connect for the latest review state of a project's pending submission.",
            category: .observe,
            parameters: [
                .init(name: "project", kind: .projectPath, prompt: "Which project?")
            ],
            phases: [
                .init(
                    id: "speak-checking",
                    displayName: "Announce",
                    action: .speak(text: "Checking App Store status for ${param.project}.", audioCueAfter: nil)
                ),
                .init(
                    id: "query",
                    displayName: "Query ASC",
                    action: .iosTool(name: "ios_check_asc_status", input: ["project": .string("${param.project}")])
                ),
                .init(
                    id: "speak-result",
                    displayName: "Report",
                    action: .speak(text: "Apple says: ${state.asc_state}.", audioCueAfter: nil)
                )
            ]
        )
    }

    // MARK: - generate-marketing-screenshots
    //
    // Standalone capture + Claude Design pass. Used to regenerate marketing
    // assets for an already-shipped app without re-running the full ship
    // workflow. Exits before walkthrough/publish so the operator can iterate
    // on copy without committing to a new submission.
    static func generateMarketingScreenshots() -> CommandV2Definition {
        CommandV2Definition(
            id: "generate-marketing-screenshots",
            displayName: "generate marketing screenshots",
            voiceTriggers: [
                "generate screenshots for {project}",
                "regenerate screenshots for {project}",
                "marketing screenshots {project}",
                "claude design screenshots {project}"
            ],
            description: "Boot a sim, build the app, capture raw frames, and run Claude Design to compose ASC-ready marketing screenshots + asc-copy.md.",
            category: .ship,
            parameters: [
                .init(name: "project", kind: .projectPath, prompt: "Which iOS project should I generate screenshots for?")
            ],
            phases: [
                .init(
                    id: "screenshots-capture",
                    displayName: "Capture raw simulator frames",
                    action: .iosTool(
                        name: "ios_generate_screenshots",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "screenshots-design",
                    displayName: "Claude Design - marketing screenshots",
                    action: .claudeAgent(
                        systemPrompt: """
                        You are the Claude Design pass for ${param.project}'s App Store screenshots.
                        Raw simulator frames live at ${state.screenshots_dir}.
                        Per Mobile App Conventions Rule 7 (App Store screenshots are MARKETING, not raw),
                        each composite combines a 5-8 word headline, sub-line ≤14 words, the raw frame inside
                        a faux-device chrome, and a brand-tinted background using the project's AccentColor.
                        Generate composites at 1290×2796 (6.5\\" iPhone) into <project>/marketing/screenshots/iphone-6.5/composed/.
                        Also write <project>/marketing/asc-copy.md with: subtitle, promotional text, keywords (≤100 chars CSV),
                        what's new (this build), and per-screenshot copy mapped to composite filenames.
                        Use Bash + Read + Write tools and `sips`/`magick`/`ffmpeg` for image composition (no external services).
                        Exit when composed/ has the same count as the raw frames AND asc-copy.md is written.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "speak-done",
                    displayName: "Announce",
                    action: .speak(
                        text: "Marketing screenshots for ${param.project} are ready. Composed assets and copy live under marketing slash screenshots.",
                        audioCueAfter: AudioCue(kind: .successChime)
                    )
                )
            ]
        )
    }

    // MARK: - ship-existing-ios-app
    //
    // Re-ship path for apps that already have a v1+ build. Skips the
    // brainstorm + 5-agent build swarm - those
    // are designed for NEW apps from a blank slate. Goes straight from
    // convention-audit → install → screenshots → walkthrough → publish.
    //
    // Voice triggers like "ship the existing {project}" / "re-ship {project}"
    // route here; the bare "ship the {project}" still routes to the full
    // ship-ios-app flow.
    static func shipExistingIOSApp() -> CommandV2Definition {
        let twentyFourHours: TimeInterval = 24 * 60 * 60
        return CommandV2Definition(
            id: "ship-existing-ios-app",
            displayName: "re-ship the existing iOS app",
            voiceTriggers: [
                "ship the existing {project}",
                "re-ship the {project}",
                "re-ship {project}",
                "publish the existing {project}",
                "ship update of {project}",
                "ship update {project}"
            ],
            description: "Re-publish path for apps with an existing v1+ build. Audit → install → marketing screenshots → walkthrough → publish → wait → check.",
            category: .ship,
            parameters: [
                .init(name: "project", kind: .projectPath, prompt: "Which existing iOS project should I re-ship?")
            ],
            phases: [
                .init(
                    id: "bootstrap-asc-credentials",
                    displayName: "Bootstrap ASC credentials (autonomous)",
                    action: .claudeAgent(
                        systemPrompt: """
                        Autonomous ASC credentials bootstrap for ${param.project}.

                        Goal: ensure ${param.project}/.grux/ship-config.json has working `ascApiKeyId`,
                        `ascApiKeyIssuerId`, `ascApiKeyPath`, and `ascAppId` before the publish phase
                        runs. Apple does NOT allow programmatic ASC API key creation - but a key from
                        any prior project on the same Apple Developer account works. Reuse it.

                        Steps:
                        1. Read ${param.project}/.grux/ship-config.json. If `ascApiKeyId` is already
                           non-TBD, skip credential discovery - go to step 4.
                        2. Search ~/.appstoreconnect/private_keys/ for `AuthKey_*.p8`. Pick the first
                           one (it's tied to the same Apple Developer account so any key works for
                           any app under that account).
                        3. Find the issuer ID by reading sibling projects' `.grux/ship-config.json`,
                           searching the parent directory of ${param.project} for other
                           `*/.grux/ship-config.json` files, newest first. Take the first non-empty
                           `ascApiKeyIssuerId`. Update ${param.project}/.grux/ship-config.json with
                           the discovered values.
                        4. Ensure ASC app record exists. Generate a JWT for the ASC API (HS256? no -
                           ES256 with the .p8 private key). Use Python with `pip install pyjwt[crypto]`
                           if needed (`/opt/homebrew/bin/python3 -m pip install --quiet pyjwt cryptography`).
                           Then GET https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=<bundleId>
                           with `Authorization: Bearer <jwt>`. If the app exists, write its numeric `id`
                           to `ascAppId` in ship-config.json. If it doesn't exist, POST to /v1/apps with
                           {data:{type:"apps",attributes:{bundleId:"<bid>",name:"${param.project}",
                           primaryLocale:"en-US",sku:"<sluggified-name>"}}} to create it, then write the
                           returned id back. Per conventions Rule 30 (paid-country exclusions), set
                           availability to all available territories EXCEPT [VEN, CUB, IRN, PRK, SYR].
                        5. Verify by GETing /v1/apps/<id> and confirming response is 200.
                        6. Print final ship-config.json + the resolved ASC app numeric id.

                        Use Bash + Read + Write + Edit. Be careful with shell quoting - the project root
                        path may contain spaces. Use double-quoting + heredocs for python.
                        Exit when ship-config.json contains all 4 ASC fields with concrete values AND
                        the GET /v1/apps/<id> verification succeeds.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "convention-audit",
                    displayName: "Audit against app conventions",
                    action: .builtin(name: "convention-audit", args: [
                        "projectDir": .string("${param.project}"),
                        "brand": .string("${param.project}")
                    ])
                ),
                .init(
                    id: "auto-fix-audit-blockers",
                    displayName: "Auto-fix audit blockers (autonomous)",
                    action: .claudeAgent(
                        systemPrompt: """
                        Autonomous blocker remediation for ${param.project}.

                        Read the audit report at ${state.audit_report_path}. For EVERY rule with
                        Status=FAIL (blocker OR warning), apply the fix in code. Don't ask. Don't
                        propose. JUST FIX. Then run xcodegen + a quick xcodebuild compile check to
                        confirm nothing broke.

                        Common fixes you must handle:
                        • Rule 29 (Export Compliance): for every Info.plist in
                          ${param.project}/Sources/**/Info.plist, add
                          <key>ITSAppUsesNonExemptEncryption</key><false/> directly inside the
                          top-level <dict>. Use /usr/libexec/PlistBuddy:
                          `PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "<plist>"`
                          (idempotently - first check with `PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption"`).
                        • Rule 7 (WCAG contrast): the failing pairs usually involve the brand accent
                          against various text colors. Open Sources/<App>/Resources/Assets.xcassets/AccentColor.colorset/Contents.json
                          (and any other brand colorset the report names) and shift the color stops so
                          foreground text on that background hits ≥4.5:1 contrast. Compute via WCAG luminance formula
                          (relative luminance L = 0.2126*R + 0.7152*G + 0.0722*B in linear sRGB; ratio
                          = (L1+0.05)/(L2+0.05)). Aim for 4.7+ to leave headroom. Don't change the hue,
                          only saturation/brightness.
                        • Rule 8 (Dynamic Type): wherever the report points, replace
                          .font(.system(size: <fixed>)) with .font(.system(.body)) (or .title, .headline
                          as appropriate by the original size).
                        • Rule 13 (Siri brand-leading): in <App>ShortcutsProvider.swift, ensure
                          every AppShortcut phrase starts with the app's name (or `\\(.applicationName)`
                          which iOS substitutes correctly when called by name first).
                        • Rule 27 (Universal Links): add <string>applinks:<the app's own domain></string> to
                          com.apple.developer.associated-domains in <App>.entitlements. Skip this rule
                          when the app has no associated domain.
                        • Rule 6 (toolbar): if non-trivial, add a brief note to ${param.project}/audits/auto-fix-deferred.md
                          and mark for manual follow-up (don't gate the ship on cosmetic toolbar).

                        After all fixes, run `cd "${param.project}" && xcodegen generate` and then a
                        quick `xcodebuild -project <App>.xcodeproj -scheme <App> -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build-device build CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<teamId from .grux/ship-config.json> 2>&1 | tail -40`
                        to confirm nothing broke. Don't fail the run if xcodebuild has warnings - only fail on `error:` lines.

                        Exit when all blockers are remediated. Print a tight summary listing each rule
                        you fixed and the file(s) you touched.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "re-audit",
                    displayName: "Re-audit after fixes",
                    action: .builtin(name: "convention-audit", args: [
                        "projectDir": .string("${param.project}"),
                        "brand": .string("${param.project}")
                    ])
                ),
                .init(
                    id: "install",
                    displayName: "Install to device",
                    action: .iosTool(
                        name: "ios_install_to_device",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "screenshots-capture",
                    displayName: "Capture raw simulator frames",
                    action: .iosTool(
                        name: "ios_generate_screenshots",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "screenshots-design",
                    displayName: "Claude Design - marketing screenshots + App Previews",
                    action: .claudeAgent(
                        systemPrompt: """
                        You are the Claude Design pass for ${param.project}'s App Store assets.
                        Raw simulator frames live at ${state.screenshots_dir} (typically 10 files).
                        Raw preview video lives at ${state.previews_dir}/preview_main.mp4 (~25 sec).

                        Per Mobile App Conventions Rule 7 (App Store assets are MARKETING, not raw),
                        Apple ranks apps that fill ALL slots: 10/10 screenshots + 3/3 App Previews.
                        Always produce the maximum.

                        DELIVERABLE 1 - 10 composed screenshots
                        For EACH raw frame in ${state.screenshots_dir}, produce a composite at
                        1290×2796 (6.5\\" iPhone) under
                        <project>/marketing/screenshots/iphone-6.5/composed/. Each composite combines:
                          • a 5-8 word headline (sentence case, brand voice, distinct per slot)
                          • a sub-line ≤14 words promising a concrete benefit
                          • the raw frame inside a faux-device chrome (Dynamic Island, rounded corners)
                          • brand-tinted background using AccentColor (gradient is welcome)
                          • optional: feature pills (Widget · Siri · Share · Markdown) for the last 1-2
                          • the project's wordmark image from Sources/**/Assets.xcassets/LaunchWordmark.imageset/
                            scaled to ~460px wide if it exists
                        Vary the headline angle across the 10 - capture, organize, find, share, accessible,
                        privacy, widgets, siri, ecosystem, fast.

                        DELIVERABLE 2 - 3 App Preview videos
                        Apple App Previews must be H.264 .mp4 (or .m4v / .mov), 15-30 sec, portrait
                        1080×1920+ (we capture 1290×2796 native). For each of 3 distinct angles
                        (\"main flow\", \"organize\", \"share/widgets\"), produce one .mp4 at:
                          <project>/marketing/previews/composed/01_main.mp4
                          <project>/marketing/previews/composed/02_organize.mp4
                          <project>/marketing/previews/composed/03_share.mp4
                        Use ffmpeg (already on PATH) to:
                          • clip preview_main.mp4 to the relevant 15-25 sec window
                          • overlay a brand-tinted lower-third with the headline (via drawtext + box)
                          • optional: 1-second branded intro/outro (solid AccentColor + wordmark)
                          • encode at -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p -r 30
                        Validate each .mp4 with `ffprobe -v error -show_streams` and confirm:
                          duration ≥ 15 and ≤ 30, codec=h264, pix_fmt=yuv420p, dimensions ≥ 1080×1920

                        DELIVERABLE 3 - asc-copy.md (or update existing)
                        Refresh <project>/marketing/asc-copy.md with: subtitle, promotional text,
                        keywords (≤100 chars CSV), per-screenshot headline+sub, per-preview script,
                        what's new (this build), and a word-count audit table.

                        Use Bash + Read + Write + Edit tools. Compose with sips, Pillow, ffmpeg.
                        REUSE marketing/scripts/composite.py from prior runs - only edit if spec changes.
                        Exit when composed/ has 10 PNGs AND previews/composed/ has 3 .mp4s AND asc-copy.md is current.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "account-health-check",
                    displayName: "ASC account health preflight",
                    action: .iosTool(
                        name: "ios_check_account_health",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "branch-on-blocker",
                    displayName: "Branch on account blocker",
                    action: .branch(
                        condition: .stateEquals(key: "account_health_ok", value: "true"),
                        ifTrue: "fix-review-blockers",
                        ifFalse: "open-account-blocker"
                    )
                ),
                .init(
                    id: "open-account-blocker",
                    displayName: "Open ASC blocker URL in Safari",
                    action: .iosTool(
                        name: "ios_open_account_blocker",
                        input: [:]
                    )
                ),
                .init(
                    id: "await-blocker-resolution",
                    displayName: "Wait for user to resolve account blocker",
                    action: .userApprovalGate(
                        prompt: "Resolve the App Store Connect blocker (Safari is open at the right page) - accept any pending agreement, then reply 'done' so I can re-check and publish.",
                        expectedReplies: ["done", "ok", "accepted", "ship it"]
                    ),
                    userApprovalRequired: true
                ),
                .init(
                    id: "recheck-account-health",
                    displayName: "Re-check ASC account health",
                    action: .iosTool(
                        name: "ios_check_account_health",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "branch-recheck",
                    displayName: "Branch on re-check",
                    action: .branch(
                        condition: .stateEquals(key: "account_health_ok", value: "true"),
                        ifTrue: "fix-review-blockers",
                        ifFalse: "await-blocker-resolution"
                    )
                ),
                // Resolve the 5 metadata blockers Apple gates "Add for Review" on:
                // privacy URL, primary category, content rights, age rating
                // (all via REST PATCH), then App Privacy data-collection (UI flow
                // driven by app-privacy-fill below). Without this, the version's
                // submission POST returns ENTITY_ERROR and the publish phase
                // wastes a build slot.
                .init(
                    id: "fix-review-blockers",
                    displayName: "Resolve ASC review-readiness blockers (REST)",
                    action: .iosTool(
                        name: "ios_fix_review_blockers",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "app-privacy-fill",
                    displayName: "Fill App Privacy questionnaire via claude-in-chrome",
                    action: .claudeAgent(
                        systemPrompt: """
                        Fill the App Privacy data-collection questionnaire for ${param.project} so the
                        "Add for Review" button is no longer gated. Apple does NOT expose this via the
                        ASC REST API - drive the web UI via claude-in-chrome MCP tools.

                        State to read: ${state.app_privacy_url} (already pre-computed by the previous
                        phase; falls back to https://appstoreconnect.apple.com/apps/<ascAppId>/distribution/privacy
                        if missing).

                        Steps:
                        1. tabs_context_mcp first. Reuse an existing appstoreconnect.apple.com tab if open;
                           otherwise tabs_create_mcp.
                        2. navigate to ${state.app_privacy_url}.
                        3. screenshot. If you see a "Get Started" button, the questionnaire is unanswered.
                           If you see "Data Not Collected" or "Last Published" text, it's already done - exit success.
                        4. find the "Get Started" button → left_click.
                        5. find "No, we do not collect data from this app" radio (assumes the app's
                           PrivacyInfo.xcprivacy declares NSPrivacyCollectedDataTypes empty - verify
                           by reading Sources/<App>/Resources/PrivacyInfo.xcprivacy first; if it lists
                           collected data types, halt and ask user). left_click.
                        6. find "Save" button in the Data Collection modal → left_click.
                        7. find "Publish" button on the App Privacy page header → left_click.
                        8. find "Publish" confirm button in the "Publish Your App Privacy Responses?"
                           modal → left_click.
                        9. screenshot to verify the page now shows "Last Published" with today's date.
                        10. Print success.

                        If any step fails (modal doesn't appear, button missing, etc.), screenshot the
                        current state, write a diagnostic to ${param.project}/audits/app-privacy-fill-failure.md,
                        and exit non-zero so the workflow halts cleanly.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "publish",
                    displayName: "Publish to App Store (autonomous)",
                    action: .claudeAgent(
                        systemPrompt: """
                        Autonomous App Store submission for ${param.project}.

                        IMPORTANT - pre-flight + post-upload verification (learned from prior runs):
                        • BEFORE archive, VALIDATE THE 1024×1024 APP ICON. Read Sources/<App>/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (or whatever Contents.json points at for the 1024 marketing icon). Run `sips -g hasAlpha -g pixelWidth -g pixelHeight <icon>`. If hasAlpha=yes, FLATTEN it onto an opaque white background using Pillow (PIL): img.convert('RGBA') → composite onto Image.new('RGB', size, (255,255,255)) using img.split()[3] as mask → save as PNG with no alpha. Apple's `iconValidation` step rejects icons with a transparent alpha channel and the rejection arrives only AFTER the build has been processed (10-30 min wasted). Width/height must be exactly 1024×1024.
                        • BEFORE upload, ALIGN VERSION FIRST. Read the project's CFBundleShortVersionString from infoPlistPath. List existing AppStoreVersions via GET /v1/apps/<id>/appStoreVersions?limit=10. If a draft AppStoreVersion exists in PREPARE_FOR_SUBMISSION state with versionString != bundle's shortVersion, PATCH /v1/appStoreVersions/<vid> to set versionString=<bundle shortVersion>. Apple's pipeline DROPS uploads silently when the build's short version doesn't match an existing draft AppStoreVersion - the upload reports success, but no build ever appears in the catalog. This is the #1 failure mode for first-publish of a new app.
                        • BEFORE upload, run `xcrun altool --validate-app -f <ipa> --type ios --apiKey <id> --apiIssuer <issuer>`. Validation surfaces signing/entitlement issues that --upload-app silently ignores.
                        • AFTER upload, poll BOTH `/v1/apps/<id>/builds` AND `/v1/builds?sort=-uploadedDate&limit=5` for 15 min. If your delivery UUID's build doesn't appear globally either, the upload was lost - re-PATCH the version + retry upload once before failing.
                        • If Apple's catalog still shows 0 builds 30 min after a successful re-upload, write a diagnostic to ${param.project}/audits/publish-failure.md explaining the symptoms (uploads accepted but catalog empty), suggesting account-level checks (agreements, banking, tax, contact info) and prompting the user. Then exit non-zero so the workflow halts cleanly. NOTE: a fresh Paid Apps Agreement acceptance can take 24-48 hours to propagate before any new build is processed - this is normal and not a bug. The fix-review-blockers + app-privacy-fill phases that ran upstream of this one have already cleared the metadata gates so the moment a build ingests, the submission can fly.

                        BLOCKER GUARANTEE: Every metadata blocker Apple gates "Add for Review" on is
                        already resolved by the upstream fix-review-blockers + app-privacy-fill phases:
                        Privacy Policy URL, Primary Category, Content Rights, Age Rating (4+),
                        App Privacy data-collection ("Data Not Collected"). Don't re-fetch them - just
                        verify with one GET on /v1/appInfos/<id> that contentRightsDeclaration is set
                        and primaryCategory exists; if EITHER is null, run ios_fix_review_blockers
                        again before continuing.

                        SCREENSHOT + PREVIEW REQUIREMENTS (Apple validation gotchas - REST surface):
                        • Screenshots: APP_IPHONE_67 set must hold 3-10 PNGs at exactly 1290×2796.
                          Reuse the existing set if present; do NOT create duplicates (Apple won't list them).
                        • App Previews: APP_IPHONE_67 previewType, 886×1920 OR 1080×1920 portrait,
                          15-30s, h264, yuv420p, EXPLICIT 30fps via ffmpeg `fps=30` filter (simctl
                          recordVideo on some Macs emits 0.17fps - Apple rejects with MOV_RESAVE_FRAME_RATE_LARGER),
                          STEREO audio track required even if silent (use ffmpeg `-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 -c:a aac -b:a 128k -ac 2 -ar 44100`),
                          else Apple rejects with MOV_RESAVE_STEREO. After PATCH-with-uploaded=true, poll
                          /v1/appPreviews/<id> until assetDeliveryState.state == COMPLETE; FAILED states
                          carry the exact error code in assetDeliveryState.errors[*].code.

                        Read ${param.project}/.grux/ship-config.json for ASC creds + ascAppId. Steps:

                        1. Bump version. Read ALL Info.plist files listed in `infoPlistPath` +
                           `subTargetPlists`. Bump CFBundleVersion (build number) by +1 in EACH plist
                           (use /usr/libexec/PlistBuddy). Keep CFBundleShortVersionString unchanged
                           unless the previous build is already on the App Store at the same
                           short version (check via ASC API GET /v1/preReleaseVersions?filter[app]=<id>).

                        2. xcodegen generate. Run `cd "${param.project}" && xcodegen generate`.

                        3. xcodebuild archive. Below, <App> is the project's scheme name and <teamId>
                           is the `teamId` field from .grux/ship-config.json. Run:
                           xcodebuild archive \\
                             -project <App>.xcodeproj -scheme <App> \\
                             -configuration Release \\
                             -destination 'generic/platform=iOS' \\
                             -archivePath build-archive/<App>.xcarchive \\
                             -allowProvisioningUpdates \\
                             DEVELOPMENT_TEAM=<teamId> CODE_SIGN_STYLE=Automatic
                           Use the runXcodebuildResilient pattern: poll for <App>.xcarchive/
                           appearing + size-stable, then proceed.

                        4. Export IPA. Write build-archive/export-options.plist with:
                           <plist><dict>
                             <key>method</key><string>app-store-connect</string>
                             <key>teamID</key><string><teamId></string>
                             <key>signingStyle</key><string>automatic</string>
                             <key>uploadSymbols</key><true/>
                           </dict></plist>
                           Then: xcodebuild -exportArchive \\
                             -archivePath build-archive/<App>.xcarchive \\
                             -exportPath build-archive/export \\
                             -exportOptionsPlist build-archive/export-options.plist \\
                             -allowProvisioningUpdates

                        5. Upload to ASC. Use altool (still functional in Xcode 26):
                           xcrun altool --upload-app \\
                             -f build-archive/export/<App>.ipa \\
                             -t ios \\
                             --apiKey <ascApiKeyId> \\
                             --apiIssuer <ascApiKeyIssuerId>
                           altool reads .p8 from ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 by convention.

                        6. Wait for processing. Poll ASC API GET /v1/builds?filter[app]=<ascAppId>&sort=-uploadedDate
                           every 30s until the latest build has processingState=VALID (typically 5-15 min).
                           Use python with pyjwt + cryptography for JWT signing (already installed from
                           bootstrap-asc-credentials phase).

                        7. Submit for review. Once VALID:
                           a. POST /v1/appStoreVersions to create a version record (or reuse existing
                              draft) tied to <ascAppId> with shortVersionString from the bumped plists.
                              IMPORTANT: PATCH the existing draft if its versionString != bundle's shortVersion.
                           b. PATCH /v1/appStoreVersions/<vid>/relationships/build to attach the build.
                           c. Read marketing/asc-copy.md for subtitle/promo/keywords/whats-new.
                              PATCH the AppStoreVersionLocalization for en-US with description, keywords,
                              promotionalText, supportUrl, marketingUrl, whatsNew (whatsNew only for updates,
                              not first release - Apple returns 409 STATE_ERROR otherwise). Also PATCH the
                              AppInfoLocalization to set subtitle.
                           d. Upload ALL 10 composed screenshots from
                              marketing/screenshots/iphone-6.5/composed/ to the APP_IPHONE_67 set via
                              /v1/appScreenshotSets + /v1/appScreenshots (3-step: reserve → PUT to
                              uploadOperations URLs → PATCH uploaded=true with md5 sourceFileChecksum).
                              See SCREENSHOT REQUIREMENTS above for size + cap.
                           e. Upload ALL 3 App Preview .mp4s from marketing/previews/composed/ via
                              /v1/appPreviewSets + /v1/appPreviews (same 3-step flow). See PREVIEW
                              REQUIREMENTS above for fps + stereo audio gotchas - both are MUST-haves.
                              Poll each upload to assetDeliveryState=COMPLETE before moving on.
                           f. POST /v1/appStoreVersionSubmissions with the version id (POST body
                              relationships.appStoreVersion.data → {type:appStoreVersions,id:<vid>}).
                              If 409 CONFLICT, the version is already submitted - treat as success.
                              If 4xx OTHER, fall back to /v2/appStoreVersionSubmissions same body.

                        8. Confirm submission. GET /v1/appStoreVersions/<vid> and verify
                           appStoreState=WAITING_FOR_REVIEW (or IN_REVIEW / PENDING_DEVELOPER_RELEASE
                           if Apple flipped quickly).

                        9. Print: build number, version, ASC app id, submission id, current state.

                        Use Bash + Read + Write + Edit. Be thorough - this is the final autonomous
                        submission with no human approval gate. If ANY step fails, write a clear
                        diagnostic to ${param.project}/audits/publish-failure.md and exit non-zero.
                        Be careful with shell quoting (project path has spaces).
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "wait-for-review",
                    displayName: "Wait 24h for Apple review",
                    action: .speak(
                        text: "${param.project} is in Apple's review queue. I'll check back tomorrow.",
                        audioCueAfter: nil
                    ),
                    scheduledFollowup: .init(
                        nextPhaseId: "check-status",
                        interval: twentyFourHours
                    )
                ),
                .init(
                    id: "check-status",
                    displayName: "Check ASC status",
                    action: .iosTool(
                        name: "ios_check_asc_status",
                        input: ["project": .string("${param.project}")]
                    )
                )
            ]
        )
    }

    // MARK: - ship-ios-app
    //
    // The marquee workflow. Implements the 9-phase state machine from
    // 2026-04-25-ios-app-launch-workflow.md.
    //
    // Phases that touch real production state (Phase 5 publish, Phase 8a
    // recover) are wired through `iosTool` so they pause-on-missing-config
    // instead of accidentally submitting. The 24-hour wait is implemented
    // via the engine's scheduledFollowup - the run is persisted, the timer
    // is re-armed across Grux restarts, and Mac reboots don't lose state.
    static func shipIOSApp() -> CommandV2Definition {
        let twentyFourHours: TimeInterval = 24 * 60 * 60

        return CommandV2Definition(
            id: "ship-ios-app",
            displayName: "ship the iOS app",
            voiceTriggers: [
                "ship the iOS app",
                "ship the ios app",
                // More specific patterns first so "ship the notes app" captures
                // project="notes app" instead of project="the notes app" via the
                // wildcard fall-through.
                "ship the {project}",
                "ship {project}",
                "publish the {project} to the app store",
                "publish {project} to the app store",
                "release the {project}",
                "release {project}"
            ],
            description: "End-to-end iOS launch: brainstorm → build → install → walkthrough → publish → wait → check → branch on rejection or celebrate. ~25 hours, mostly hands-off.",
            category: .ship,
            parameters: [
                .init(name: "project", kind: .projectPath, prompt: "Which iOS project should I ship? (path or alias)")
            ],
            phases: [
                .init(
                    id: "brainstorm",
                    displayName: "Brainstorm the spec",
                    action: .claudeAgent(
                        systemPrompt: "Use the superpowers:brainstorming skill on ${param.project}. Open the project's CLAUDE.md and README.md if they exist. If the workspace is empty (brand-new app), do NOT exit prematurely - instead, write a spec file at <workspace>/spec.md based on the chat conversation the user is having with you. The spec MUST contain: title, one-line pitch, target audience, 3-5 core user flows, screen list (names + purposes), data model (entities + fields), success metrics, and explicit non-goals. Only exit AFTER the spec.md file exists on disk.",
                        tools: ["fs_read", "fs_write", "shell", "chat"],
                        maxTokens: nil
                    )
                ),
                // HARD GATE - explicit approval phase. Catches the failure mode where
                // the brainstorm claudeAgent exits prematurely without writing a spec.
                // Verifies spec.md exists AND requires the user to type 'go' / 'approved'
                // before the 4-parallel build swarm can fire (which would otherwise
                // burn ~$0.40/min thrashing on an empty workspace).
                .init(
                    id: "brainstorm-approval-gate",
                    displayName: "Confirm spec before launching build swarm",
                    action: .userApprovalGate(
                        prompt: "Spec ready? Reply 'go' / 'approved' / 'ship it' to fire the 5-agent build swarm. Reply 'more' to keep brainstorming. Do NOT auto-approve on the user's behalf - wait for them to actually type one of these words in chat.",
                        expectedReplies: ["go", "approved", "looks good", "ship it", "build it", "lgtm"]
                    ),
                    userApprovalRequired: true
                ),
                // Register the new app on Apple's side BEFORE install. Apple's REST
                // /v1/apps endpoint forbids POST (FORBIDDEN_ERROR), so the only way
                // to mint a new ASC App ID is via the web UI. This phase drives
                // claude-in-chrome to fill the New App form and capture the App ID
                // from the resulting URL, then writes <project>/.grux/ship-config.json
                // with all the constants (Team ID, ASC keys, bundle, signing identity)
                // sourced from the user's global config. After this phase, install can run.
                .init(
                    id: "register-asc-app",
                    displayName: "Register app on App Store Connect (Chrome)",
                    action: .claudeAgent(
                        systemPrompt: """
                        Register ${param.project} on App Store Connect so install can proceed. Apple's REST API forbids POST /v1/apps (returns 403 FORBIDDEN_ERROR) - you MUST drive the web UI.

                        BROWSER: Chrome only (never Safari). Use claude-in-chrome MCP tools. If `mcp__claude-in-chrome__tabs_context_mcp` returns "No Chrome extension connected", fall back to AppleScript to navigate Chrome (`osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "..."'`) and ask the user to manually click the claude-in-chrome extension icon to reconnect - then retry.

                        PUT THE FORM IN FRONT OF THE USER + SPEAK THE INSTRUCTIONS - every time, not just on MCP failure. Even if claude-in-chrome works, they want the form visible AND verbal guidance because their hands are not always free:
                        a. `open -a "Google Chrome" "https://appstoreconnect.apple.com/apps"` - brings Chrome forward + opens the apps page
                        b. `osascript -e 'tell application "Google Chrome" to activate'` - force frontmost
                        c. `say -v "Samantha" -r 175 "App Store Connect is in front of you. Click the plus, choose new app. Name: <name>. Bundle: <the configured bundle prefix, spoken as words> dot <lowername>. SKU: <lowername>. Then paste me the app ID from the URL." &` - verbal walkthrough running in background while they read the on-screen field summary you also print to stdout
                        d. If the URL after `open` shows `authResult=FAILED` or `/login`, ALSO speak "App Store Connect needs you to log in first" - Apple SSO needs the user's own hands.

                        STEPS:
                        1. Read project name from ${param.project}'s CLAUDE.md or docs/spec.md (the user-facing "Display name" field). Read bundleId - should be <the configured bundle prefix>.<lowername>. If a /v1/bundleIds GET shows it doesn't exist, POST it first via API (that endpoint IS allowed): {"data":{"type":"bundleIds","attributes":{"identifier":"<bundle>","name":"<DisplayName>","platform":"IOS"}}}.
                        2. Navigate Chrome to https://appstoreconnect.apple.com/apps. If logged out, ask the user to log in (you can't drive Apple SSO).
                        3. Click "+ → New App". Fill: Platforms=iOS, Name=<display name from spec, fallback to "<basename> Stories" if Apple says name taken>, Primary Language=English (U.S.), Bundle ID=<the one we registered>, SKU=<lowername>, User Access=Full Access. Submit.
                        4. After submission, the URL bar reads appstoreconnect.apple.com/apps/<APP_ID>/... - capture <APP_ID>.
                        5. Write <project>/.grux/ship-config.json with all 7 review-blocker fields populated from defaults (privacyPolicyUrl="<the project's own privacy policy URL>", supportUrl="<its support URL>", marketingUrl="<its marketing URL>", primaryCategory based on app type - UTILITIES default for productivity/notes, BOOKS for journal-style apps, ENTERTAINMENT for media, contentRightsDeclaration=DOES_NOT_USE_THIRD_PARTY_CONTENT, ageRatingPreset=ALL_AGES_4_PLUS). Plus the constants: ascAppId=<APP_ID>, bundleId, teamId=<the Apple Developer team id, from a sibling project's .grux/ship-config.json or from Grux's config.json `developerTeamId`>, ascApiKeyId + ascApiKeyPath=<the AuthKey_<KEYID>.p8 found in ~/.appstoreconnect/private_keys/>, ascApiKeyIssuerId=<the issuer id from a sibling project's ship-config.json>, distSigningIdentity=<the "Apple Distribution: ..." line from `security find-identity -v -p codesigning`>, distProvisioningProfile="App Store Distribution Profile", infoPlistPath="<basename>/Info.plist", subTargetPlists=["<basename>Widget/Info.plist"] if widget exists.
                        6. Verify shape with `cat <project>/.grux/ship-config.json | python3 -m json.tool`. Print success line with the App ID.

                        If Apple rejects the name as taken, try "<original> Stories", "<original> Tales", "<original> Journal" before asking the user for an override.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "build",
                    displayName: "Swarm build (5 agents × up to 6 iterations)",
                    action: .claudeAgentSwarm(
                        prompts: [
                            "Implement the spec slice owned by Agent 1 (e.g. Home).",
                            "Implement the spec slice owned by Agent 2 (e.g. Player / primary feature).",
                            "Implement the spec slice owned by Agent 3 (e.g. Profile / settings).",
                            "Implement the spec slice owned by Agent 4 (e.g. Auth / onboarding).",
                            "Implement the spec slice owned by Agent 5 (secondary screens + tab bar)."
                        ],
                        sharedTools: ["fs_read", "fs_write", "shell", "ios_build_verify"]
                    )
                ),
                .init(
                    id: "convention-audit",
                    displayName: "Audit against app conventions",
                    action: .builtin(name: "convention-audit", args: [
                        "projectDir": .string("${param.project}"),
                        "brand": .string("${param.project}")
                    ])
                ),
                .init(
                    id: "install",
                    displayName: "Install to device",
                    action: .iosTool(
                        name: "ios_install_to_device",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "screenshots-capture",
                    displayName: "Capture raw simulator frames",
                    action: .iosTool(
                        name: "ios_generate_screenshots",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "screenshots-design",
                    displayName: "Claude Design - marketing screenshots",
                    action: .claudeAgent(
                        systemPrompt: """
                        You are the Claude Design pass for ${param.project}'s App Store screenshots.
                        Raw simulator frames live at ${state.screenshots_dir}. Per Mobile App Conventions Rule 7
                        (App Store screenshots are MARKETING, not raw screenshots), each ASC slot must combine:
                          • a short headline (5-8 words, sentence case, brand-voice)
                          • a sub-line that promises a concrete benefit (≤14 words)
                          • the raw frame, scaled inside a faux-device chrome with a brand-tinted background
                          • a 3-frame storyboard for the App Preview video idea (separate file)
                        Generate one composite PNG per ASC slot at 1290×2796 (6.5\\" iPhone). Use the project's
                        AccentColor for backgrounds and the project's wordmark from <project>/marketing/brand/
                        if present, otherwise compose a simple wordmark from the project name.
                        Save composites under <project>/marketing/screenshots/iphone-6.5/composed/.
                        Also produce <project>/marketing/asc-copy.md with: app subtitle, promotional text,
                        keywords (≤100 chars CSV), what's new (this build), and per-screenshot copy mapped 1:1
                        to the composite filenames.
                        Use Bash + Read + Write tools as needed. Avoid generating images via external services -
                        compose with sips, ffmpeg, or `magick` (ImageMagick) which is on the user's PATH.
                        Exit when composed/ has the same count as the raw frames and asc-copy.md is written.
                        """,
                        tools: ["fs_read", "fs_write", "shell"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "walkthrough",
                    displayName: "Walkthrough",
                    action: .walkthrough(points: [
                        WalkthroughPoint(
                            title: "What's new in this build",
                            body: "I'll narrate each change from the diff. Reply 'ship it' when ready, or tell me what to adjust."
                        )
                    ]),
                    userApprovalRequired: true
                ),
                .init(
                    id: "publish",
                    displayName: "Publish to App Store",
                    action: .iosTool(
                        name: "ios_publish_to_appstore",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "wait-for-review",
                    displayName: "Wait 24h for Apple review",
                    action: .speak(
                        text: "${param.project} is in Apple's review queue. I'll check back tomorrow.",
                        audioCueAfter: nil
                    ),
                    scheduledFollowup: .init(
                        nextPhaseId: "check-status",
                        interval: twentyFourHours
                    )
                ),
                .init(
                    id: "check-status",
                    displayName: "Check ASC status",
                    action: .iosTool(
                        name: "ios_check_asc_status",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "decide-next",
                    displayName: "Branch on review state",
                    action: .branch(
                        condition: .anyOf([
                            .ascSubmissionState(equals: "READY_FOR_SALE"),
                            .ascSubmissionState(equals: "PROCESSING_FOR_DISTRIBUTION"),
                            .ascSubmissionState(equals: "PENDING_DEVELOPER_RELEASE")
                        ]),
                        ifTrue: "celebrate",
                        ifFalse: "still-pending-or-rejected"
                    )
                ),
                .init(
                    id: "still-pending-or-rejected",
                    displayName: "Branch on rejection vs. still-pending",
                    action: .branch(
                        condition: .anyOf([
                            .ascSubmissionState(equals: "REJECTED"),
                            .ascSubmissionState(equals: "METADATA_REJECTED"),
                            .ascSubmissionState(equals: "INVALID_BINARY"),
                            .ascSubmissionState(equals: "DEVELOPER_REJECTED")
                        ]),
                        ifTrue: "rejection-recover",
                        ifFalse: "still-pending"
                    )
                ),
                .init(
                    id: "still-pending",
                    displayName: "Still pending - wait another 24h",
                    action: .speak(
                        text: "Apple is still reviewing ${param.project}. I'll check again tomorrow.",
                        audioCueAfter: nil
                    ),
                    scheduledFollowup: .init(
                        nextPhaseId: "check-status",
                        interval: twentyFourHours
                    )
                ),
                .init(
                    id: "rejection-recover",
                    displayName: "Recover from rejection",
                    action: .claudeAgent(
                        systemPrompt: "Apple rejected ${param.project}. The feedback was: ${state.asc_feedback_text}. Read the project's CLAUDE.md, draft a fix plan, present it to the user for approval, then apply the fix and re-publish.",
                        tools: ["fs_read", "fs_write", "shell", "ios_build_verify"],
                        maxTokens: nil
                    ),
                    userApprovalRequired: true
                ),
                .init(
                    id: "celebrate",
                    displayName: "Celebrate (interrupt-on-active)",
                    action: .interruptOnNextActive(
                        message: "Also, good news - ${param.project} is approved on the App Store. You shipped anotha one.",
                        audioCue: AudioCue(kind: .djKhaledAnotherOne, postSpeakDelay: 0.4)
                    )
                )
            ]
        )
    }

    // MARK: - localize-app
    //
    // Per Rule 26 (Mobile App Conventions): Ship Day = English only.
    // Exactly one week post-approval, this command wakes up, asks "any
    // final thoughts on this project specifically?", and if yes feeds the
    // dictation back to a swarm that incorporates the feedback alongside
    // the localization pass. If no, proceeds straight to translation.
    //
    // Triggered automatically by the ship-ios-app `celebrate` phase
    // scheduling a 1-week followup; can also be invoked manually:
    //   "localize {project}" / "translate {project}"
    static func localizeApp() -> CommandV2Definition {
        let oneWeek: TimeInterval = 7 * 24 * 60 * 60
        return CommandV2Definition(
            id: "localize-app",
            displayName: "localize {project}",
            voiceTriggers: [
                "localize {project}",
                "translate {project}",
                "translate the {project} app"
            ],
            description: "One week post-launch: prompt for final thoughts, then localize the app to ja/de/fr/es/zh-Hans via the asc-fix-07/08 scripts.",
            category: .ship,
            parameters: [
                .init(name: "project", kind: .projectPath, prompt: "Which project should I localize?")
            ],
            phases: [
                .init(
                    id: "wait-one-week",
                    displayName: "Wait one week post-launch",
                    action: .speak(
                        text: "${param.project} just shipped. I'll check back in a week before localizing.",
                        audioCueAfter: nil
                    ),
                    scheduledFollowup: .init(
                        nextPhaseId: "ask-final-thoughts",
                        interval: oneWeek
                    )
                ),
                .init(
                    id: "ask-final-thoughts",
                    displayName: "Ask for final thoughts",
                    action: .userApprovalGate(
                        prompt: "It's been a week since ${param.project} shipped. Any final thoughts on this project specifically - around design, audience, or product fit? Reply 'yes' to dictate, 'no' to proceed straight to localization, or 'skip' to defer the localization pass.",
                        expectedReplies: ["yes", "no", "skip"]
                    ),
                    userApprovalRequired: true
                ),
                .init(
                    id: "incorporate-feedback",
                    displayName: "Incorporate week-later feedback (if any)",
                    action: .branch(
                        condition: .anyOf([
                            .stateEquals(key: "user_reply", value: "yes")
                        ]),
                        ifTrue: "swarm-feedback-pass",
                        ifFalse: "translate"
                    )
                ),
                .init(
                    id: "swarm-feedback-pass",
                    displayName: "Swarm: incorporate week-later feedback",
                    action: .claudeAgent(
                        systemPrompt: "The user just shared week-later feedback on ${param.project}: ${state.user_dictation}. Open the project's CLAUDE.md and the live-on-App-Store version. Triage the feedback into a fix list. If the changes are non-trivial, draft them as a v.next bump and re-run ship-ios-app. If they're cosmetic, apply them inline now and proceed to translation.",
                        tools: ["fs_read", "fs_write", "shell", "ios_build_verify"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "translate",
                    displayName: "Localize to ja/de/fr/es/zh-Hans (asc-fix-07/08)",
                    action: .iosTool(
                        name: "ios_localize_app",
                        input: [
                            "project": .string("${param.project}"),
                            "locales": .array([
                                .string("ja"), .string("de"), .string("fr"),
                                .string("es"), .string("zh-Hans")
                            ])
                        ]
                    )
                ),
                .init(
                    id: "celebrate-localized",
                    displayName: "Celebrate localization completion",
                    action: .interruptOnNextActive(
                        message: "${param.project} is now live in 6 languages on the App Store.",
                        audioCue: AudioCue(kind: .djKhaledAnotherOne, postSpeakDelay: 0.4)
                    )
                )
            ]
        )
    }

    // MARK: - testflight-feedback
    //
    // Surfaces TestFlight beta feedback (crash reports + tester comments)
    // for a project still in the 24-72h beta gate before App Store submit.
    // Wakes the user with the digest, lets them triage (drop bug into
    // fix-list / dismiss / hold for later), then loops back to ship-ios-app for the
    // final rebuild + ASC submission.
    //
    // Auto-triggered by ship-ios-app's testflight-gate phase OR manually:
    //   "show testflight feedback for {project}" / "testflight {project}"
    static func testflightFeedback() -> CommandV2Definition {
        return CommandV2Definition(
            id: "testflight-feedback",
            displayName: "TestFlight feedback for {project}",
            voiceTriggers: [
                "testflight feedback for {project}",
                "testflight {project}",
                "show me testflight feedback for {project}",
                "tester feedback on {project}"
            ],
            description: "Pull TestFlight crash reports + tester comments via ASC, present a triage digest, and loop fixes back into ship-ios-app before App Store submission.",
            category: .ship,
            parameters: [
                .init(name: "project", kind: .projectPath, prompt: "Which project's TestFlight feedback?")
            ],
            phases: [
                .init(
                    id: "fetch-feedback",
                    displayName: "Fetch TestFlight feedback from ASC",
                    action: .iosTool(
                        name: "ios_testflight_feedback",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "speak-digest",
                    displayName: "Narrate the triage digest",
                    action: .speak(
                        text: "${param.project} TestFlight: ${state.tf_crash_count} crashes, ${state.tf_comment_count} tester comments. Top issue: ${state.tf_top_issue}.",
                        audioCueAfter: nil
                    )
                ),
                .init(
                    id: "triage-gate",
                    displayName: "Triage the feedback",
                    action: .userApprovalGate(
                        prompt: "Should I incorporate this TestFlight feedback into a fix-pass before App Store submission? Reply 'fix' to spin up the fix swarm, 'ship' to skip and submit as-is, or 'hold' to wait for more tester input.",
                        expectedReplies: ["fix", "ship", "hold"]
                    ),
                    userApprovalRequired: true
                ),
                .init(
                    id: "decide-action",
                    displayName: "Branch on triage decision",
                    action: .branch(
                        condition: .anyOf([
                            .stateEquals(key: "user_reply", value: "fix")
                        ]),
                        ifTrue: "fix-swarm",
                        ifFalse: "decide-ship-or-hold"
                    )
                ),
                .init(
                    id: "decide-ship-or-hold",
                    displayName: "Branch ship vs hold",
                    action: .branch(
                        condition: .anyOf([
                            .stateEquals(key: "user_reply", value: "ship")
                        ]),
                        ifTrue: "trigger-asc-submit",
                        ifFalse: "hold"
                    )
                ),
                .init(
                    id: "fix-swarm",
                    displayName: "Spawn fix swarm against TestFlight feedback",
                    action: .claudeAgent(
                        systemPrompt: "TestFlight feedback for ${param.project}: ${state.tf_full_report}. Open the project's CLAUDE.md, triage each issue, fix the code, bump build number, re-archive, re-upload to TestFlight. After upload, hand off to ship-ios-app.",
                        tools: ["fs_read", "fs_write", "shell", "ios_build_verify"],
                        maxTokens: nil
                    )
                ),
                .init(
                    id: "trigger-asc-submit",
                    displayName: "Hand off to ship-ios-app's publish phase",
                    action: .iosTool(
                        name: "ios_publish_to_appstore",
                        input: ["project": .string("${param.project}")]
                    )
                ),
                .init(
                    id: "hold",
                    displayName: "Hold for more tester input",
                    action: .speak(
                        text: "Holding ${param.project} TestFlight. Ping me when more feedback comes in.",
                        audioCueAfter: nil
                    )
                )
            ]
        )
    }

    // MARK: - capture-idea
    //
    // "Grux, idea: ..." dictation. Writes the spoken content to
    // ~/.grux/ideas/<id>.md and queries the companion Lance vector store at
    // :3850 for a top-1 prior match. Threshold 0.85 (server-side score, which
    // is 1 - cosine_distance / 2 with bge-base-en-v1.5 normalized embeddings)
    // surfaces near-duplicates without blocking the capture. Soft-fails when
    // the companion is asleep: the .md file lands either way.
    static func captureIdea() -> CommandV2Definition {
        CommandV2Definition(
            id: "capture-idea",
            displayName: "capture idea",
            voiceTriggers: [
                "idea: {content}",
                "idea {content}",
                "grux idea: {content}",
                "grux idea {content}",
                "new idea: {content}",
                "new idea {content}",
                "capture idea: {content}",
                "capture idea {content}"
            ],
            description: "Drop a spoken or typed idea into the queue. Dedupes against prior ideas via the remote RAG service.",
            category: .lifestyle,
            parameters: [
                .init(name: "content", kind: .freeText, prompt: "What's the idea?")
            ],
            phases: [
                .init(
                    id: "capture",
                    displayName: "Write idea + dedup against prior captures",
                    action: .builtin(name: "capture-idea", args: [
                        "content": .string("${param.content}")
                    ])
                ),
                .init(
                    id: "speak-result",
                    displayName: "Speak the result",
                    action: .speak(
                        text: "${state.idea_spoken_message}",
                        audioCueAfter: nil
                    )
                )
            ]
        )
    }
}
