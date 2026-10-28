# Files that name themselves: design

Written 2026-10-27. The owner asked for this feature, built to a polished end product and shown working on his own Mac. Branch `feat/files-name-themselves`, stacked on `fix/local-title-once` (it needs `ModelBackend.completeShortAnswer`, which that branch adds).

## Intent

Most Mac folders are full of files named by a clock or a server: `Screenshot 2026-10-27 at 9.41.03 AM.png`, `document(3).pdf`, `IMG_4471.jpeg`. With this feature on, a new screenshot or a new download names itself from what it shows: `Stripe Invoice Oct 2026.png`, `Lease Renewal 2027.pdf`. The person does nothing different. Nothing about the file leaves the Mac.

The product test: a person takes a screenshot of an invoice, and a second later Finder shows it as "Stripe Invoice Oct 2026.png". One click on Undo puts the old name back.

## Goals

1. New screenshots in the screenshot folder, and new images and PDFs in Downloads with machine-made names, are renamed from their content within a few seconds of landing.
2. Fully on device: Apple Vision reads the text from images, PDFKit reads PDFs, and a model served by Ollama on this Mac (loopback only) writes the name. If no on-device model is available, the feature does nothing and says why in Settings. It never falls back to a cloud model.
3. Every rename can be undone: from the notification, from the list in Settings, and from the `~/.grux/fire-file-naming-undo-last` trigger.
4. Off by default. Named at first run, it has a permanent Settings home and its off state is explained (Grux-Mac/CLAUDE.md, "nothing ships OFF and undiscoverable").

## Non-goals (v1)

- Moving or filing files into folders. The name changes; the folder does not.
- Images with no readable text (photos). These are left alone. A vision model would be needed, and on a 16 GB Mac it would not fit beside the chat model.
- Renaming anything already in the folders when the feature is turned on. Only files that appear after the watcher is armed.
- Other file types: movies, archives, disk images, documents other than PDF.
- A Grux Local model change or a GPU swing. The held-out eval decides whether one is needed (see Eval). The answer may be "not yet".
- A new row in the feature registry. This is a capability like screen control, not a surface. The registry is pinned at 37 rows by `RegistryReachabilityTests` and `FeatureSelectionTests` and by the published "37 features" copy. Do not add a row.

## Anti-goals: a failure even if it technically works

- Renaming a file a person named themselves. A false positive here is the worst outcome. When unsure, leave it alone.
- A name built from words that are not in the file (a hallucination). Also a name that carries a secret, a full card number or a password.
- A rename that loses the file, changes its extension, moves it out of its folder, or overwrites another file.
- File text or the new names written to logs (WakeLog, NSLog). The user's content stays out of logs.
- Making a person's chat turn wait. A chat turn always goes first.
- Any prompt or folder access before the person turns the feature on (`LaunchTouchesNoProtectedFolderTests`).

## Constraints

- House copy rules: no em or en dashes anywhere, US spelling, 12-hour clock. The guards are `NoTypographicDashesTests`, `USSpellingTests`, `NoTwentyFourHourClockTests`, `JargonInTheFaceTests` and `ProductNameTests`.
- `NoPersonalIdentityTests` bans personal names and brands in `.swift` string literals and `.md`. Test fixtures use neutral text, for example "Northwind Studio" and "Acme", never a personal name, a city, or a machine or brand name from the banned list.
- Tests compile and run only on public CI (macOS 15, about 34 minutes). The 16 GB test Mac can `swift build` the app but cannot compile the test target, because it has no XCTest. Test code must be right the first time, so copy patterns that already compile in this repo.
- Live state: watch with `FileWatch` (a DispatchSource vnode source per folder), never a timer poll as the main mechanism.
- The sandbox is off, so the boundary is in Swift. Model output is untrusted (SECURITY.md section 2).

## Measured facts this design rests on (2026-10-27)

- The screenshot folder comes from `defaults read com.apple.screencapture location`: a tilde path (on the owner's MacBook `~/Documents/`), with `~/Desktop` when the key is absent. When `target` is `clipboard`, no file is written.
- A keyboard screenshot carries the xattr `com.apple.metadata:kMDItemIsScreenCapture` (mdls `1`). A `screencapture -x <path>` file does NOT.
- A screenshot lands as hidden temp files (`..name-XXXX`, then `.name`) and is renamed to its final name about 0.7 s after the capture starts. Downloads arrive as `.crdownload`, Safari `.download` bundles or growing files.
- With `think: false`, the base `qwen3.5:4b` gave these names in 0.6 to 0.9 s each once loaded: "Stripe Invoice Oct 2026", "Swift Build Error Log", "Mom Sunday Dinner Plans", "Delta Boarding Pass Nov 14" and a city weather report. The first call, 3.0 s, included loading the model.

## How it works

### Which files

A file is a candidate when ALL of these hold:

1. It appeared in a watched folder after the watcher was armed. The watcher keeps a snapshot of names at arm time and acts only on names that are new against it.
2. It is not partial or hidden: no leading `.`, and none of the suffixes `.crdownload`, `.download`, `.part`, `.partial`, `.tmp`, `.opdownload`. It is a regular file, not a package.
3. Its size has stopped changing: the same size on two reads 0.5 s apart, waiting at most 60 s.
4. Its kind is an image (`png`, `jpg`, `jpeg`, `heic`, `tiff`, `gif`, `webp`) or a `pdf` (case-insensitive extension).
5. Either:
   - **Screenshot folder:** it carries the `kMDItemIsScreenCapture` xattr. If the screenshot folder is also Downloads, the Downloads rule applies to everything else.
   - **Downloads:** its base name looks machine-made (below).
6. Its base name is not on FilesystemTool's deny list (`denyBasename`/`matchesDeniedBasename`).

**Looks machine-made** (`FileNamingRules.looksMachineMade(_ baseName:)`, pure and table-tested). True when the name, without its extension and without a trailing ` (n)`, `(n)` or `-n` copy counter, is any of:

- a generic word, alone or followed by digits, `_`, `-` or spaces: `document`, `download`, `file`, `image`, `img`, `scan`, `untitled`, `unknown`, `attachment`, `invoice`, `receipt`, `statement`, `export`, `print`, `photo`, `pic`, `screenshot`, `screen shot`, `pxl`, `dsc`, `dcim`;
- no letters at all after removing separators (`20261027_094103`, `1693`);
- a UUID or hex run of 16+ characters (`a3f9...`);
- a camera or app stamp: `IMG_1234`, `IMG-20261027-WA0001`, `PXL_20261027_...`, `Screenshot_20261027-...`, `CleanShot 2026-...`, `Screen Recording ...`;
- a code-like token with digits making up 40% or more of its non-separator characters (`C0855-1693`, `INV-000123`).

Anything else is treated as a name a person could have typed, and is left alone: `Lease renewal 2027`, `taxes`, `Q3 deck final`. Lean toward false. The table test must include at least 15 human names that stay false and 15 machine names that turn true.

### Reading the text

`FileTextReader.text(of:kind:) async -> String`, off the main actor:

- **Image:** `CGImageSource` decode, then `VNRecognizeTextRequest` with `.accurate`, `usesLanguageCorrection = true` and automatic language detection. Lines are joined in reading order.
- **PDF:** `PDFSupport`'s text extraction for the first 3 pages. If that is empty (a scan), render page 1 with `PDFSupport.thumbnail` at 2000 px and OCR it.
- The result is capped at 3,000 characters and run through `SecretRedactor.redact(_, passes: .evidenceOnly)`.
- Under 12 letters in total means too little text: leave the file alone, with the reason `noText`.

### Naming

`FileNamePrompt`:

- `system`: the naming instruction. Start from the probe prompt above: 2 to 6 words, brand or person, kind of thing, month or subject when shown, Title Case, no date stamps, no extension, no quotes, name only.
- `user(text:)` wraps the text.
- The call is `completeShortAnswer` with `maxTokens: 24`, `temperature: 0`, `spanName: "files.autoname"`, `feature: "file_autoname"`.

`FileNamePrompt.clean(_ reply: String, sourceText: String) -> String?` is pure and returns nil to mean "leave the file alone":

1. Take the first line. Trim quotes, backticks, `*` and `#`, and a trailing `.` or extension.
2. Replace `/`, `:`, `\` and control characters with a space. Strip any leading `.`. Collapse whitespace.
3. Keep 2 to 8 words and at most 60 characters, cutting at a word boundary.
4. **Hallucination guard:** at least one word of 3+ letters in the name must appear in `sourceText` (case-insensitive, diacritics-insensitive). Otherwise nil.
5. **Secret guard:** nil if the name holds a run of 6+ digits, or `REDACTED`.
6. nil if fewer than 2 letters remain.

### Renaming

`FileRenamer` (pure where possible, given a `FileManager`):

- `uniqueName(base:ext:in:)` gives `"<base>.<ext>"`, then `"<base> 2.<ext>"`, `"<base> 3.<ext>"`, and so on. The extension keeps its original case.
- `rename(_ url: URL, to base: String) throws -> URL` uses `FileManager.moveItem` within the same folder only. Before the move it checks that the source still exists with the same size and file identifier (inode) recorded at settle time. If the person renamed or moved the file meanwhile, it is skipped.
- Grux's own rename fires the directory event again. The service keeps a set of names it produced, and the snapshot logic must never re-process them.

**Ledger:**

- `FileRenameLedger` at `Persistence.supportDir/FileNaming/ledger.json` keeps the newest 200 entries.
- Each entry is a `FileRename { id: UUID, folder: String, oldName: String, newName: String, at: Date, undoneAt: Date? }`.
- `undo(id:)` renames back only when the new name still exists and the old name is free. Otherwise it reports why and changes nothing.
- `undoLast()` undoes the newest entry that has not been undone.
- The ledger lives under `supportDir`, so tests are isolated automatically. It never creates a user-visible folder (`NoSurpriseFoldersTests`).

### The service

`@MainActor final class FileNamingService` (`static let shared`):

- `apply(enabled: Bool)` is driven by an observer on `AppState.shared.$config.map(\.fileNamingEnabled).removeDuplicates()`, started once at launch. When on, it resolves the folders, takes snapshots and arms one `FileWatch`. When off, it stops everything and drops the queue. Nothing touches Desktop, Documents or Downloads while it is off.
- **Folders:** the screenshot folder from `com.apple.screencapture` (re-read on each arm), plus `~/Downloads`. Deduplicated. Missing folders are skipped.
- **On a FileWatch event:** list the folders, diff against the snapshot, enqueue new candidates. A serial queue processes one file at a time.
- **Model route** (`FileNamingRoute.resolve() async -> Route?`), LOCAL ONLY:
  - `config.ollamaBaseURL` must pass `LocalTurn.isLoopback`.
  - Run `ModelRegistry.shared.discoverLocal()` if `local == nil`.
  - Require `localServedByOllama` and `localUsable`.
  - The model is the installed `grux-local` tag for this Mac's memory (8 GB tier `2b`, 16 GB tier `4b`, 24 GB and up `9b`, through `HardwareProfile`/`MemoryTier`). Else any installed `grux-local` tag. Else `config.offlineLLMModel`.
  - The backend comes from `resolvedRouting(provider: "local", modelOverride: tag)`.
  - No route means skipped with reason `noLocalModel`, and Settings shows why.
  - Never `AmbientLLM`, `provider: nil`, `"anthropic"` or `ClaudeClient`. A source-text test asserts that.
- **Yielding to chat:**
  - Wait while `AppState.shared.chatTurnInFlight`.
  - Then `LocalModelGate.shared.acquire()`, re-check, call, release. This is the `warmLocalPrefix` pattern.
- **After a rename:** append to the ledger, then post a notification with an Undo action (below).
- **Status (no content):** `enabled`, `armed`, `route` (`ok`, `noLocalModel` or `notLoopback`), `model` (tag), `folders` (paths), `named`, `undone`, `skipped` by reason (`humanName`, `noText`, `modelDeclined`, `changedMeanwhile`, `unsupported`, `error`), `lastNamedAt`.
- **WakeLog:** only `autoname:` events with the reason, the model and ms. Never text or names.

### Notification

- A `UNNotificationCategory` with the identifier `grux.fileNamed` and one action, `grux.fileNamed.undo` ("Undo"), registered with the existing ones in `Notifications.swift`.
- Title "Renamed", body `“<new name>”`. The user info carries the ledger id. The response handler calls `undo(id:)`.
- Shown only when Grux's notifications are authorized. No new permission request here.

### Settings and first run

- **GruxConfig:**
  - Property `fileNamingEnabled: Bool`, CodingKey, memberwise init default `false`.
  - Decode exactly `fileNamingEnabled = try c.decodeIfPresent(Bool.self, forKey: .fileNamingEnabled) ?? false`.
  - Classified in `OffByDefaultDiscoverabilityTests.classified` with the phrase `"Files can name themselves"`.
- **First run:** `HowItWorksStep` gets a new `point("Files can name themselves", "...")` beside the screen control point. It says what it does, that it is off until turned on in Settings, that it reads the text on this Mac only, and that it never moves a file or renames one a person named. No permission request in that step.
- **Settings:** a section `"Files that name themselves"` in the Data & Security, Capabilities sub-tab, anchored `.id("data.fileNaming")`. It holds:
  - the toggle "Name new screenshots and downloads from what they show";
  - the caption explaining the off state: what it does, which folders, that it is on device only, needs a Grux Local or other Ollama model on this Mac, and never moves files or touches names a person typed;
  - a status line from the service (route and model, or why it is idle);
  - the last 10 renames, each as "old name to new name" with an Undo button.
- **Search entry** `data.fileNaming` with keywords `rename`, `file names`, `screenshot`, `screenshots`, `downloads`, `pdf`, `name files`, `undo rename`. Alias `rename`.
- **Info.plist:** add `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription` and `NSDownloadsFolderUsageDescription`, each one sentence saying Grux reads new screenshots and downloads there to name them when "Files that name themselves" is on.
- **`docs/contract.md`:** if `scripts/check-contract.py` or `PermissionWhyContractTests` require a row for a new permission class, add it as a dated CR amendment, copying CR-29 to CR-31. Run `python3 scripts/check-contract.py --self-test` and the check.

### Triggers (hands-free verification)

Register in `Triggers/AppTriggers.swift` through a `FileNamingTriggers.register(in:on:)`, modelled on `WorkflowTriggers`:

- **`fire-file-naming-status`:** writes `file-naming-status.json` (the status above, `writtenAt` ISO8601, atomic, sorted keys).
- **`fire-file-naming-undo-last`:** undoes the newest rename, then writes the status.
- **`fire-file-naming-preview`** (contents = an absolute path): runs the whole pipeline on that file without renaming it. It writes `file-naming-preview.json` with `{ path, decision, reason, proposedName (string or null), readMs, modelMs, model }`.
  - This is the eval harness's entry point. It runs even when the feature is off, needs the local route, and ignores the "appeared after arming" rule.
  - It is the only place a proposed name is written to disk outside the rename itself. It runs only when someone fires it on their own Mac.

Add all three rows to the Grux-Mac/CLAUDE.md trigger table.

## Tests (all must compile on first push)

- `FileNamingRulesTests`:
  - `looksMachineMade` table: 15+ true, 15+ false.
  - The partial and hidden filters.
  - Kind by extension.
  - Screenshot folder resolution from a defaults dictionary: tilde expansion, absent key gives Desktop, clipboard target gives nil.
- `FileNamePromptTests`:
  - `clean` covers quotes, a path separator, a trailing extension, overlong input, the hallucination guard (a name with no word from the source gives nil), a digit run, a one-word reply and an empty reply.
- `FileRenamerTests` (temp folder):
  - unique names;
  - rename keeps the extension and stays in the folder;
  - a file changed meanwhile is skipped;
  - undo restores the name;
  - undo refuses when the old name is taken or the new file is gone;
  - the ledger is capped at 200.
- `FileNamingServiceTests`:
  - With a fake backend (copy `RecordingBackend`'s shape from `ChatRoutingTests.swift`, file-private, conforming to `ModelBackend` in full) and a temp folder, a new candidate gets renamed and ledgered.
  - A human-named PDF is left alone.
  - A file present before arming is never touched.
  - The model's nil reply leaves it alone.
- `FileNamingRouteTests`: a non-loopback base URL gives no route. A source-text test checks that `FileNaming/` never names `AmbientLLM`, `ClaudeClient`, `provider: nil` or `"anthropic"`, with a positive control.
- `FileNamingConfigTests`: default false, a missing key decodes false, round trip (copy `ConfigKeepOnTopTests`).
- `FileNamingDiscoverabilityTests`:
  - the onboarding phrase is present;
  - `SettingsView.swift` contains `state.config.fileNamingEnabled = v`;
  - `SettingsSearchRegistry.matches("rename")` finds `data.fileNaming`;
  - the anchor `.id("data.fileNaming")` exists.
- `FileNamingTriggersTests`: the status trigger writes JSON with the documented keys and no file names, modelled on `WorkflowTriggersTests`. The names pin is in `AppTriggers.swift`.
- `OffByDefaultDiscoverabilityTests.classified` gets the new entry.

Every test must be seen failing: a red-proof commit breaks each guard and public CI must fail on each named test.

## Eval (decides whether a GPU swing is needed)

A private harness under `Grux-Mac/factory/eval/file-naming/`. `factory/` is excluded from the public tree, so it is never in the public replay.

- **`items/`:** 150 synthetic documents, no personal data. Each is an HTML page rendered to PNG by headless Chrome, or to PDF.
  - Categories: invoices and receipts, bank and card statements, tickets and boarding passes, chat screenshots, email screenshots, code errors and terminal output, settings dialogs, articles, recipes, calendar views, spreadsheets, slides, product pages, maps and weather, forms (lease, tax, insurance), and 15 photos or graphics with almost no text.
  - Each item has gold `must` keyword groups (any-of within a group, all groups required, case-insensitive) and an `expectLeftAlone` flag for the no-text ones.
- **`run.py`:** copies each item to a temp folder on the target Mac, fires `fire-file-naming-preview`, reads the JSON, and scores.
- **`score`:**
  - **Useful:** the name meets every `must` group.
  - **Left alone correctly:** a no-text item gives `noText`.
  - **Wrong:** anything else.
  - Also latency (`readMs + modelMs`) p50 and p95.
- **Bar, pre-registered**, per memory tier, on the 16 GB test Mac with the model warm:
  - useful 90% or more on text items;
  - left alone correctly 95% or more on no-text items;
  - p95 3.0 s or less per file.
- **Swing rule:** if the 16 GB tier model (4b) meets the bar, ship. If the 8 GB tier (2b) misses, write a mission card `factory/missions/file-naming-2b.md` to fold naming data into the next Grux Local training round. Publishing it needs the maintainer's go-ahead. Do not train a separate namer model: a second model would not fit beside chat.

## Demo, on the owner's MacBook

1. Build on the 16 GB test Mac (`swift build -c release` through `build.sh` with the open shim). Copy to the MacBook, sign with the pinned identity, install over `/Applications/Grux.app`.
2. Write `~/.grux/config.json` so Grux opens past first run, on the loopback Ollama with `gruxai.com/grux/grux-local:4b` (pulled 2026-10-27) and `fileNamingEnabled: true`.
3. macOS asks once for access to the Documents and Downloads folders. The owner says "click Allow" with Voice Control. That step is his: present, offer the phrase, pause, verify by `fire-file-naming-status`.
4. Take a real keyboard screenshot of a synthetic invoice page (Cmd-Shift-3 through screen control, or the owner's Voice Control "press command shift 3").
5. Show the Documents folder in Finder: the screenshot is named from its content. Then the Undo from Settings.

## Left to the builder

Exact copy wording within the house rules, internal type names beyond the ones fixed above, and how the Settings list is laid out (follow `GruxTheme` and the screen control section).
