# Grux 3.0 evidence

One line per gate item, with the artifact. Appended as phases close.

## Baseline (2026-09-20, main 1edb4bf)

- `swift build`: Build complete.
- `swift test`: Executed 2502 tests, with 10 tests skipped and 0 failures in 149.029 seconds.

## Phase A

- DoD 4, destructive never: `DestructiveNeverTests` red-proven 2026-09-20. Planted `case .never: _ = await cmd.run(); outcome = .executed` in `VoiceCommandRouter.consider`: "Executed 1 test, with 2 failures". Restored; `diff` against the backup printed nothing; rerun "Executed 1 test, with 0 failures".
- DoD 5, the wake-word downgrade from one control: live build 2026-09-20 10:30 (pid start 10:30:23, binary mtime 10:30:19). `touch ~/.grux/fire-wake-enable` then `mic-status.json`: `mode=wakeWord ambientListening=False ambientCapturing=False wakeWordListening=True ambientPref=False wakePref=True`. `touch ~/.grux/fire-ambient-enable`: `mode=alwaysOn ambientListening=True ambientCapturing=True wakeWordListening=False ambientPref=True wakePref=False`. The two consent dialogs were answered "Turn it on" through System Events on the operator's own machine at the operator's stated decision (always on).
- Race found and fixed the same run: two triggers fired together interleaved their stop/start pairs and wrote a transient `off` while ambient was capturing. `apply()` is now serialized; `test_concurrentApplies_doNotInterleave` pins the order.
- Task A7, Listening control and Decisions card: live captures 2026-09-20 (kept outside the tree because they show the operator's own data): `~/.claude/handoffs/grux-3-0-evidence/a7-settings-listening-2026-09-20.png` (Voice & Ambient, Ambient sub-pane: segmented Always on / After Hey Grux / Off, explanation, policy line, mic note, status "Listening, hearing you", Show what it heard) and `a7-integrations-decisions-2026-09-20.png` (Decisions card first in Integrations: Not connected, Get a key, secure field, Save & Test).
- Sweep fix the same run: with always on active the Ambient HUD (untitled, 392x1020) is on screen at launch and `winid` listed it first, so `grux-sweep.sh` captured the HUD for every tab and reported NEVER DIVERGED. The sweep now prefers the window titled "Grux OS". Also added the `listening` deep-link alias.
- Chat responsiveness (the operator's "why are you not responding", 2026-09-20): root causes in order. Chat pinned to a local 3B model behind a 130k character prompt (80 to 90 s a turn); the Anthropic key rejected and its balance out; error bubbles stored as assistant turns and parroted; a failed-swarm notice injected on every launch; and every Keychain item written by the `security` tool raising a login prompt that froze the main thread for minutes. Fixed by routing Chat to OpenRouter deepseek-v4-flash through a custom endpoint with its own model id and the OpenRouter provider shape, `isNotice` filtering, the transition-gated injector, and `~/.grux/fire-endpoint-key` so Grux writes its own Keychain items (log: `endpoint key import: stored for 7A1F0E5C...` at 11:49:42, item cdat 20260920154942Z). Turn after: first stream event at +2.67 s, hop closed at +3.60 s, real reply in the thread file.
- The television test (DoD 1, chatter never reaches Chat): log 12:19:17 `ambient (focus): → chat: (burping) (burping) - That MGM really creates unforgettable moments.` was the defect. After the router owns always on, driven through `~/.grux/fire-ambient-inject` under the live Jev provider: `not_a_command ignored conf=1.00 463ms jev` for the advert, the same for a bystander's sentence, and `say:chat executed conf=0.95 613ms jev` for "Hey Grux, what time is it right now?" with the reply "It's 12:34 PM EDT, Sunday, September 20." 4.2 s after the chunk. `test_televisionAdvert_neverReachesChat` red-proven by planting "the best" into the dictation phrases: "XCTAssertEqual failed: executed is not equal to ignored"; restored, diff empty.
- Wake-phrase macro: `sig_dawn_patrol` (trigger "hey Grux", shell step) claimed "Hey Grux, what time is it right now?" and refused it (`macro:sig_dawn_patrol refused conf=0.95`). Address stripped before the question; macros never own a wake phrase; `test_wakePhraseMacro_neverClaimsAnAddressedSentence`.
- Prompt measured with `~/.grux/fire-chat-context-dump`: before, 130,306 characters (116 tools = 79,725; stable 42,757; a poisoned THREAD_SUMMARY of 2,198 written by the local model from notices). After ToolRelevance and the developer block: 73,912 characters (57 tools = 33,394; stable 35,070), one hop, "ping ok 2026" at +3.46 s. The poisoned summary was cleared on disk with Grux stopped; compaction now drops notices (`test_compactionFiltersNoticesBeforeSummarizing`).
- Orb Anywhere removed at the operator's word (2026-09-20). Zero references remain in Sources, Tests, docs, scripts (`command grep -rIn "OrbAnywhere|orbAnywhere|fire-orb-anywhere"` empty).
- Focus card: `docs/superpowers/evidence/2026-09-20-focus-card/sheet-expanded.png` (right top, left top, left bottom, right bottom: orb on the outer edge, collapse control on the inner edge) and `sheet-collapsed.png`. Frames read back from the app: right top card (2333,2376,332,134) to orb (2601,2446,64,64), same top-right corner (2665,2510); left top card (137,2376) to orb (137,2446), same left edge; left bottom card and orb both at y=1133. Two aborts on the way (NSHostingView `updateAnimatedWindowSize` inside `windowDidLayout`, crash reports 13:04:42 and 13:09:04) fixed by holding the hosting view in a plain container.
- Speech engine restart on output configuration change: code path in `SpeechEngine.handleOutputConfigurationChange`. NOT PROVEN live: switching the default output between the eqMac virtual device and the built-in speakers while speaking (12:35) posted no configuration change, and the install uses system TTS (`useElevenLabs: false`), which never goes through this engine. The operator's high-pitched AirPods playback is most likely the eqMac virtual device mishandling the AirPods rate change; unproven either way.
- Hearing logs (operator's "check hearing logs", 13:25): `ambient (always on): not_a_command ignored conf=0.45 475ms jev` on "That was fucked. You responded in high-pitched language..." said 6 s after Grux spoke; and three `inject-chat: '⚠️ UNPROCESSED FAILED SWARM'` lines at 13:19:21, 13:22:01, 13:24:41 matching three `swift test` runs, each answered aloud ("Your move: retry, change scope, or abandon?"). Cause: `testStartSwarmAppliesTheClamp` started a real swarm through the shared service (284 probe jobs in the operator's store, all removed). After the fix: full suite 2567 tests, 0 failures, and `grep -c "UNPROCESSED"` on the live log during the run = 0. Continuity replay under Jev (13:39): "Hey Grux, say the word ready" answered "ready"; the complaint 6 s later reached Chat (`say:chat executed conf=0.95 453ms`) and was answered "You're right, that was off. I'll keep it plain and steady from here."; the advert 9 s after that: `not_a_command ignored conf=0.97`.
- Always-on listening stays on the Mac's own microphone (2026-09-20, the operator's AirPods report). The defect, from the log: at 12:19 with AirPods connected, `ambient: VoiceProcessingIO ENABLED (AEC/NS/AGC) for 08-FF-44-06-EA-EF:input` and `ambient: engine up native=24000Hz ch=3`, the hands-free call codec, which is what a headset drops to while anything holds its microphone. `ListeningMicPolicy` classifies Bluetooth, AirPlay and Continuity capture as borrowed and moves listening to the built-in microphone (or to a wired one the person chose); `ListeningMicGuard` puts their device back when the last listener stops, and leaves it alone if they changed it meanwhile. Proven live with a Continuity device, no Bluetooth input being connected: system input set to "Apple Iphone 8 Microphone", listening started at 15:34:56 → `listening mic: Listening moved off Apple Iphone 8 Microphone to MacBook Pro Microphone`, `VoiceProcessingIO ENABLED ... for BuiltInMicrophoneDevice`, `engine up native=48000Hz ch=5` (against 24,000 Hz on the headset), and at 15:35:05 on stop → `listening mic: put the input back to Apple Iphone 8 Microphone`, confirmed by `SwitchAudioSource -c -t input` at each step. NOT PROVEN with Bluetooth: no Bluetooth input was connected, and the AirPods case is the same branch with `blue` in the same set. Red-proven by planting an early `return nil` in `inputToUse`: 6 of 9 failures; restored, `diff` empty.
- `list_ui` stopped calling off-screen Accessibility frames click-ready. Found by `ScreenControlProofTests` going red on this machine: 60 of 80 Finder elements reported centres near y = -7,000 against displays spanning y = 0 to 2,557, because a row scrolled out of a list keeps an Accessibility frame where it WOULD be. Same coordinates on a second run, so not flakiness. `ScreenControlEngine.isOnADisplay` drops them; red-proven by planting `return true`, 1 failure, restored, `diff` empty.
- Full suite after both: Executed 2579 tests, 10 skipped, 0 failures in 154.8 s.

## Phase A, the tells (P-A8-1 to P-A8-5, P-A10-1), 2026-09-20

- **One word, every surface.** `ListeningTell.resolve` is the only thing that
  answers "what is the microphone doing", and the sidebar orb, the menu bar,
  the ambient HUD and Chat all ask it. `ListeningTellTests` enumerates every
  combination of mode, mute, speaking and thinking. Red-proven by restoring the
  original bug (armed falling through to idle) and by dropping the mute rule:
  5 of 10 red, source restored byte-identical by `diff`.
- **The bug this closes, measured on the running app.** Always-on listening
  drives no wake listener, so the Chat chip said the wake word was off while
  the microphone was live. Capture after the fix: `/tmp/shots-a8/home-chat.png`,
  sidebar pill `ARMED`, Chat chip `ARMED`, binary mtime Sep 20 18:53:53, app
  relaunched 18:54 and confirmed running by `ps`.
- **Live under Jev, two injections through the real path.** Chatter
  ("and then the whole crowd started cheering for the other team") answered
  `not_a_command` at 1.00 in 598 ms. Command ("hey grux open my notes")
  answered `tab:notes` at 0.99 in 383 ms, executed, and the Notes tab opened.
  Both rows in `~/Library/Application Support/Grux/decisions.jsonl`.
- **The rail renders what the ledger recorded.** Same capture, bottom of Chat:
  `hey Grux open my notes` in white, `opened Notes` in green, `383 ms`
  monospaced, `1 more` for the chatter line behind it.
- **A regression found by looking rather than by a test.** The rail takes
  height from the conversation when it appears, which slid the last message
  underneath it. Fixed by re-pinning on the rail's row count, and only when
  the reader was already at the bottom.
- **Suite.** 2627 executed, 10 skipped, 0 failures after the identity fix
  below. It was 1 failure before: `NoPersonalIdentityTests` caught the
  operator's first name in the work log committed as `af0c476`, so main was red
  from that commit until `f050b56` and no run had been done in between.

## Phase A gates on the engine, and the first of Phase B, 2026-09-20

- **P-A9-1, P-A9-2, P-A9-4** closed: the engine is a veto on the chat fast path,
  a second opinion on shell commands, and a tightener on the Jax gate. In all
  three the hand-rolled guard is the FLOOR and the provider may only raise the
  verdict. On device a yes or no question answers 0.5, which is the provider
  saying it cannot judge, so a keyless install behaves exactly as before.
- **A regression I shipped and an existing test caught.** `ChatService.send` is
  main-actor isolated, so the await I added above the readiness guard was a
  suspension point: a turn that should have been refused locally reached the
  network and came back with a provider error, 4.2 seconds against a 0.5 second
  budget. Fixed in `39029ec` by matching synchronously and only suspending once
  there is a plan. `ChatIntentRoutingTests` now pins the source order.
- **THE SUITE WAS WRITING TO THE RUNNING APP, measured from a screenshot.** The
  Self-Upgrade timeline held 1,000 rows, all of them test noise: 667 "Auto-land
  paused (crash-loop breaker)" and 333 "Demoted". Worse, self-install was
  PAUSED on the machine with the reason recorded as "restored after
  FoundryGovernorTests", because that test calls `clearAutoLandPause()`, the
  human-only control. `Persistence.supportDir` is a per-process temporary
  directory under test now, which closes the class rather than one store.
  Full suite green with it: 2682 executed, 10 skipped, 0 failures. The poisoned
  timeline and the test-tripped breaker were backed up to
  `~/Library/Application Support/Grux/backups-2026-09-20/` and cleared.
- **Phase B started.** Thread titles (`92b355e`), repeated error bubbles
  (`3ab31e4`), the composer footer (`25a09dd`) and the composer backdrop
  (`deb885d`). All four verified on the running app: binary mtime and capture
  paths recorded in the ledger rows.
- **Plans now exist for every phase**, A through G, so no packet is blocked on
  a missing one.

## Phase B: P-B-1 and P-B-4 closed, 2026-09-20

- **Suite: 2697 executed, 10 skipped, 0 failures.** Floor was 2653.
- **P-B-1** closed across `92b355e`, `3ab31e4`, `d9e7d93`. Thread titles, repeated
  error bubbles, the header, and message sidedness. Every test red-proven.
- **P-B-4** closed at `103741d`. The jargon test found six real defects on its
  first run, all of them the sentences a person reads when a turn fails, and it
  forced a real conflict into the open: four existing tests asserted the shown
  sentence MUST name the status code. Resolved by keeping what the code stood
  for (specific and actionable) and dropping the code itself. The caller keeps
  the status; only the face loses it.
- **Verified on the running app**, `/tmp/shots-b2/home-chat.png`: composer reads
  `Llama3.2 | about $0.03`, the composer is dark rather than a grey slab, and
  the orb and Chat chip both read ARMED.

## Phase B: P-B-2 and P-B-3 closed, 2026-09-20

- **Suite: 2715 executed, 10 skipped, 0 failures.** Floor was 2697.
- **Verified on the running app**, `/tmp/shots-b3/home-chat.png`, binary installed
  and relaunched before the capture. The header reads the thread name
  ("omi parity push") where it read "CURRENT TASK / No current task. Ask me
  what to work on." The chips read ARMED and WILL SPEAK with a small `ai` glyph
  beside them. The composer reads "Ask me anything, or just say it out loud".
  The Compact thread gradient slab is a "Thread" menu. The footer reads
  "Llama3.2" and "about $0.03".
- **The title repair worked on real data.** The thread titled
  "big teets and http 400" is gone from the rail. Its preview was itself error
  text, so it fell back to the neutral default, and the auto-titler will name it
  properly on the next turn in that thread. That self-healing is why the repair
  falls back rather than leaving a status code in place.
- **What the capture still shows, honestly:** thread PREVIEW lines still quote
  the old "(HTTP 400)" copy, because those are stored message bodies from before
  the copy was rewritten. New failures will not read that way. Rewriting history
  in a person's own transcripts was not done and should not be.

## G-B: the Phase B gate, closed 2026-09-20

**Suite:** 2729 executed, 10 skipped, 0 failures. Floor was 2653.

**The finished face, item by item, against the accepted finish list.** Captures
`/tmp/shots-b3/home-chat.png` (Chat) and `/tmp/shots-b5/chat-home.png` (Home),
both taken after installing and relaunching.

| item | before | after |
|---|---|---|
| no status codes as thread titles | `big teets and http 400` | repaired and gone |
| dedupe repeated error bubbles | six identical red bubbles | one card with a count |
| thread title as the header | `CURRENT TASK / No current task.` | `omi parity push` |
| system messages never render as the person | labelled `GRUX` | labelled `NOTICE` |
| state chips replace vendor chips | `WAKE OFF`, `ELEVEN LABS` | `ARMED`, `WILL SPEAK` |
| plain footer | `llama3.2:3b \| est $0.0294 \| i...ok \| cheaper: qwen3.5:4b free` | `Llama3.2 \| about $0.03` |
| Compact thread becomes a menu item | full-width gradient slab | a `Thread` menu |
| auto-discard empty threads | a column of `New chat` | discarded unless starred |
| Find a chat | VERIFIED already present | unchanged |
| composer placeholder invites speech | no placeholder at all | `Ask me anything, or just say it out loud` |
| plain empty states | VERIFIED already satisfied and tested | unchanged |
| the vendor glyph | a vendor as a status chip | one size smaller behind `ai` |
| real name on Home | VERIFIED already wired | `Good evening, <name>` |
| setup nag to a Settings badge | `5 features need setup`, permanently | a badge on the Settings row |
| needs-you count in the rail | `245` (an inbox size) | `48` (what wants something) |
| Listening and Mute in the foot | absent | `ARMED`, tapping toggles mute |
| group failed jobs with retry | VERIFIED already satisfied | unchanged |
| plain-language Settings copy | one opaque voice identifier in prose | removed, guarded by a test |
| one Labs badge instead of pills | six pills | **MOVED TO PHASE C C2**, see below |

**The one item that moved, and why.** Removing the per-row BETA pills was
reverted. `BetaBadgeTests` guards a promise onboarding makes: experimental
features are labelled, because an unlabelled empty shell is indistinguishable
from a broken tab. Phase B's plan said remove here and let Phase C add the door
badge, which breaks that promise for however long Phase C takes. A gap between
a removal and its replacement is a regression even when both halves are
planned. It becomes a MOVE in C2, where both halves land together.

**Sweep counts, reconciled by name.**
- Vendor sites: 18 files mention a vendor; 1 rendered one as a status chip on
  the face and is now behind the glyph; 3 are comments; the rest are Settings,
  Developer, Labs and Onboarding surfaces or credential copy where the vendor
  is the actionable noun.
- Settings copy: 214 user-facing strings reviewed; 20 carry technical
  vocabulary; 19 are the correct word for the thing being configured, which is
  why the jargon test exempts Settings; 1 was a real defect and is fixed.

## Phase C begins: P-C-1 closed, P-C-2 half landed, 2026-09-20

**Suite: 2754 executed, 10 skipped, 0 failures.** Floor was 2737.

- **P-C-1** (`9bda63f`): every one of the 39 registry rows records exactly one
  door. Counts asserted and reconciled: 12 rail, 3 studio, 9 folds, 5 developer,
  7 labs, 2 brand-scoped, 1 ripped. Red-proven with four plants.
- **P-C-2 model** (`18b614e`): the rail computed from those dispositions.
  Fourteen rows at first run, which is where the Definition of Done's number
  comes from. Red-proven with three plants.
- **A real gap the reachability work found rather than a test confirming what
  was already believed.** The registry names rows in dotted form and the
  sidebar names tabs in camelCase, and 13 of 39 do not match. Phone companion
  is dispositioned to Labs and has no tab anywhere: it opens the Pair iPhone
  window. Computing a door's contents from dispositions without that mapping
  would have listed a row that opens nothing, and `--open-tab` falls through to
  chat silently, so nothing would have reported it.
- **What is deliberately NOT done:** the view still renders the old 35-key,
  5-group sidebar. Swapping the app's primary navigation deserves its own pass
  with a visual verification loop rather than being rushed at the end of a long
  one. The model and the mapping are everything that pass needs.

## P-C-2 closed: the rail is a projection now, 2026-09-20

**Suite: 2758 executed, 10 skipped, 0 failures.**

**Capture** `/tmp/shots-c2/chat-home.png`, installed and relaunched first. The
rail reads Home, Chat, Mail, Calendar, Notes, Documents, Contacts, Tasks,
Meetings, Schedules, Integrations, Studio, then the brand rows, then
`DEVELOPER 5`. Mailbox is relabelled Mail and Design Studio is relabelled
Studio, and the Mail row carries 48 rather than 245.

**The regression check that mattered.** A fold or a door that drops a key does
not fail: `--open-tab` falls through to `chat` silently, so every script and
every sweep would go to Chat and report success. All 35 locked keys were fired
through `~/.grux/fire-open-tab` against the running app and all 35 acknowledged
themselves.

**A probe that lied twice before it told the truth.** The first sweep reported
13 mismatches and the second reported 2. Both were the probe: it slept a fixed
interval rather than waiting for a fresh acknowledgement, so it read the
PREVIOUS key's ack. The returned values were previous keys in the sequence,
which is what staleness looks like rather than what a routing bug looks like.
Deleting the ack and waiting for it to be rewritten gives 35 of 35. This is the
same trap the sweep harness documents as trap 1, met from a different direction.

**Known and deliberate:** the brand-scoped rows still carry BETA pills, because
`tier` and `disposition` answer different questions and the pills move to the
Labs door in C2's sibling work rather than disappearing. See the P-B-5 note.

## A regression I shipped, and the hole in the test that caught it, 2026-09-20

**Suite: 2762 executed, 10 skipped, 0 failures.**

**What I broke.** The computed rail (`e9062be`) removed the folded surfaces
from the sidebar while their parents did not host them yet, so Speakers,
Workflows, Folders, Projects, Skills and the Focus log were reachable only by
firing `~/.grux/fire-open-tab` by hand. That is a debug hatch, not a door. Same
shape as pulling the BETA pills before the Labs door existed, and the rule I
wrote for that one applies unchanged.

**The fix** (`b2b72a5`): a surface whose new home does not host it yet keeps its
row, tracked in `SidebarIA.awaitingTheirNewHome`, which shrinks by one per
landed fold and disappears entirely when empty.

**What the new test found that I had not.** Research and Media Studio sit
behind the Studio row, which currently opens Design Studio alone. Eight
surfaces were stranded, not six.

**The honest number.** The Definition of Done says at most 14 rail rows at
first run. It is 22 today: 14 plus what has not moved. The test asserts
`14 + props` so the figure can only fall, and becomes a flat 14 when the list
empties. The first twelve rows are already the design's twelve.

**A hole in my own test, closed.** It asserted that the three folds which never
had a rail row "need no propping", which is not the same claim as "reachable".
Each route is now named and asserted: Webhooks inside Integrations (this fold
has ALREADY LANDED), Compose from the menu bar, Approvals inside Jax HQ. Red
proven by deleting `WebhooksView()` from `IntegrationsView`.

## Two findings from an attempted rip that was reverted, 2026-09-20

**Suite back to 2762 executed, 10 skipped, 0 failures after the revert.**

**The Domain monitor rip is not the small job it looks like.** Its registry note
says "no page of its own yet", which is true about tabs and false about the app.
`Empire/EmpireDashboardWindow.swift:280` links to the GoDaddy portfolio,
`key.godaddy` is read by shipping code so removing the registry row orphaned a
live credential, and `KeychainStore.Key` carries `goDaddyApiKey` and
`goDaddyApiSecret`, which this repo is emphatic about never removing casually.
Five tests failed, each a real guard. Reverted, and the Phase C plan now carries
the order to do it in and the reason it is not a broader pass.

**`ListeningControllerTests.test_concurrentApplies_doNotInterleave` IS FLAKY.**
It failed once inside a full-suite run and passed 3 of 3 in isolation
immediately afterward. It guards a real invariant: two callers applying a
listening mode at once must not interleave their stop and start pairs, and the
controller's own comment records that interleaving "wrote a transient off while
ambient was in fact capturing". A flaky guard on that invariant is worth
treating as a defect in the test, not as noise. It is NOT caused by any change
in this session; it surfaced under suite load.

## P-E-1: the Tuning visuals, rendered and awaiting one decision, 2026-09-20

Three shapes at the app's real 1040x732, 2x, in tokens read from source rather
than approximated. Rail at its measured 240pt. Paths in the ledger row.

**What rendering at 1:1 showed, which is the entire reason the plan insisted on
1:1 rather than a wireframe:** seven dials do not fill the window. Two of the
three shapes leave roughly the bottom third empty. Tuning as a rail surface is
currently bigger than the thing it holds, and that is a question about the
brief rather than about the layout. Three ways to answer it are written up, with
a recommendation and an explicit note that the call outranks the recommendation.

**Fidelity stated rather than implied:** HTML, so rail glyphs are Unicode
stand-ins for SF Symbols and there is no vibrancy, blur or motion. Shape and
density are faithful; texture is not. A visual accepted at the wrong fidelity is
a decision made about something that does not exist.

Labs deliberately not rendered: its shape depends on the Phase C door work,
which is half landed, so rendering it now would be a guess dressed as a proposal.

## The first fold lands, 2026-09-20

**Suite: 2763 executed, 10 skipped, 0 failures.**

C8, Folders into Settings. It is the allowlist of places Grux may read and
write, so it sits with the other security questions. A fourth segment inside
Data and Security rather than a sixth top-level pane, because that picker
carries a long comment about what a fifth long label already cost it at the
840pt window floor, and repeating a measured mistake is worse than making a new
one.

**Verified by looking:** `docs/superpowers/visuals/evidence-fold-folders.png`
shows Data and Security with Folders selected and the real folder list
rendering (Unsorted 18, Work, Personal, Projects), and no Folders row left in
the rail. Driven with `settings:folders` through `fire-open-tab`, which is the
deep-link this fold added, because a fold changes where a surface lives and
never whether its name works.

Props down from 8 to 7. That list is the only thing between here and the
fourteen-row Definition of Done item, and it can only shrink.

## P-R-8 and P-R-9: the load and the audio, 2026-09-21

**Suite: 2790 executed, 10 skipped, 0 failures** (`6204058`). Installed and
running from that commit.

### P-R-8, load

Measured with `scripts/measure-idle-load.sh` (90 s uptime, then 12 `top`
readings 5 s apart; `ps %cpu` is a decaying average and was not used). Same
state before and after: main window off screen, the Focus pill on screen,
Chrome frontmost.

| state | before | after |
|---|---|---|
| muted (acceptance criterion 7) | **33.3%**, 128 MB | **1.0%**, 140 MB |
| armed | 38.2% (voice processing on for AirPods) | 12.9% (the output had moved to the speakers, so voice processing was correctly on; about 10 points of it is that echo canceller) |

The second profile, not an assertion (`profile-summary.txt`): the display cycle
went from 1248 main thread samples to 6, `NSHostingView.layout` from 947 to 1,
SwiftUI display-list renders from 505 to 0, the rail's Mail scan from 58 to 2.

Three causes. The orbs looped in SwiftUI, which re-renders the window every
frame; their turn and rings are now Core Animation (`OrbLayers.swift`). The
Focus pill joins every Space and held `MotionSuspension`'s gate open forever;
it opts out through `MotionLivesOnTheRenderServer`. The rail rescanned every
message per render; `MailStore.needsYouCount` is memoized. Also removed: an
unread `@ObservedObject` on the root and a `@Published` transcript nobody read.

The pill still moves: `pill-frame-a.png` and `pill-frame-b.png`, 1.3 s apart,
differ in 1159 pixels inside the orb. `MusicWatcher` was checked and is not a
cost: a 30 s utility-queue tick, absent from the profile.

Independent review of the aggregate diff found one real bug: a live
reduce-motion toggle did not reach an orb already turning. Fixed in `59e6521`
with a red-proven test.

### P-R-9, audio

Voice processing now runs only when the microphone can hear the output
(`VoiceProcessingPolicy`, from lane P-R-9, reviewed and merged). Live, the first
launch on AirPods logged `ambient: VPIO BYPASSED (output is Bluetooth, the mic
cannot hear it)`; every earlier launch that day logged `VoiceProcessingIO
ENABLED`. The output-route watcher was proven live twice: speakers made it
enable voice processing, and restoring the AirPods made it `restarted for
output change (output is Bluetooth...)`.

**Live verification found a bug the unit tests could not.** Without voice
processing, ambient reported capturing and heard nothing (`buf=0.0s
rms=0.0000` every tick), and the AirPods sat at 24 kHz, the Bluetooth call
profile. Probes measured the mechanism: the engine was built before the mic
was chosen and, unbound, sat on a default-device aggregate at the AirPods'
clock; bound to the MacBook Pro Microphone, its `outputFormat` stayed stale at
24 kHz and a tap in it got 0 frames in 2 s, while a tap in the bound device's
`inputFormat` got 96000. Fixed in `c2ffe57` and `9353011` (engine after the
mic, explicit bind, hardware format), pinned by `CaptureEngineOrderTests`.
Ambient now logs `hearing Ns of audio` or `DEAF` two seconds after every start;
live on `6204058`: `ambient: hearing 2.0s of audio`.

Also fixed on the way: `build.sh` raced a slow quit and twice left no Grux, or
the old binary, running (`b8a7e7e`); the suite wrote into the operator's real
`wake.log`, whose lines carry no date (`6204058`).

**NOT PROVEN, and what proves it:** the AirPods path on the fixed build. The
operator moved the output to the speakers at 10:03, and switching their audio
device while they are using the machine is not a test step. The next time the
AirPods are the output, `wake.log` will say `VPIO BYPASSED` then `hearing` (or
`DEAF`), and `system_profiler SPAudioDataType` should show the AirPods at 48000
Hz rather than 24000. The by-ear check is the operator's.

## P-R-1: one decision call per judged event, 2026-09-21

**Suite: 2797 executed, 10 skipped, 0 failures** (`10c8493`), installed.

**Live, real key, running app:** an injected, unaddressed "note that the bar
soap is always a 2 pack" produced ONE ledger row: `voice+chat.intent jev 443ms
in 4578`, `chat.intent.meant=0.23, voice.intent=not_a_command 0.72`, ignored
with no side effect. Before, a spoken request that reached Chat paid the voice
call (p50 444 ms) and then a second `chat.intent` call on the same words.

**The wire shape was measured, not assumed** (`/v1/systemone`, grux-ecosystem
key, three rounds each, order alternated):

| shape | voice answer | chat.intent | latency | input tokens |
|---|---|---|---|---|
| two separate calls | not_a_command 0.97 | 0.68 to 0.71 | 728 to 912 ms | 409 + 347 |
| one call, every context in one state | **say:chat 0.66** | 0.86 | 1037 ms (cold) | 504 |
| one call, second gate's context in its own instructions | not_a_command 0.97 to 0.98 | 0.51 to 0.54 (first wording) | 386 to 401 ms | 480 |

The middle row is why the state is the owner gate's own. Chat's wording was
then calibrated over seven utterances (four right plans, three wrong ones:
wrong day, "I should note that", a question): with its full standalone context
in front of its instructions it tracked the standalone call to a mean 0.05
(max 0.08), and separated right from wrong plans by +0.52, against +0.36 for
the standalone call.

Criterion 1: `DecisionEngine.batchViolations` records a gate that decides
directly for a surface an open event covers. Red-proven by handing Chat no
pre-decision: "a spoken request paid 2 round trips". Criterion 5 holds: a
keyless event answers each gate on device against its own state
(`test_keylessEventAnswersEveryGateAsItsDirectCallWould`), and a lone gate is
identical on the wire to its old direct call, so all 80 existing gate and
decision tests pass unchanged.

Correction on the record: the plan said a `shell_run` dispatch paid two calls.
It does not; the gate queues it and returns, and the second opinion runs only
on the approved replay. The real double was the spoken request above.

## P-R-2: the voice vocabulary, trimmed, 2026-09-21

**Suite: 2801 executed, 10 skipped, 0 failures** (`ef6bfb4`), installed.

Where the tokens went: 35 tabs at five phrasings each, and 103 speakable
macros carrying about 6,600 characters of trigger phrases on EVERY chunk.

Probe on the live API, twelve cases, same instructions and state as the app:

| shape | same choice as today | median input tokens | median latency |
|---|---|---|---|
| everything (today) | 12/12 (8 match my expectation; the 4 misses are identical in every shape and are the operator's own `dash_calendar` and `dash_gmail` macros, plus two cases the follow-up window decides) | 4,450 | 412 ms |
| macros that share a word with what was heard | 12/12 | 1,762 | 366 ms |
| that, plus compact tab phrasing | 12/12 | 1,326 | 360 ms |

Shipped the middle row. The third saves 10% more but changes on-device exact
matches ("open my calendar" would fall below the execute threshold) and
lowered provider confidence.

Live on the running app, the same injected unaddressed sentence as P-R-1:
`voice+chat.intent jev 341ms in 2298`, against `443ms in 4578` before. Room
chatter: `voice jev 385ms in 2179`, against about 4,468 before. The app sends
more than the probe's 1,762 because common short words ("the", "that") give
many macros a nonzero on-device score, and those must stay for exact keyless
parity.

Keyless parity is by construction: macros are filtered by
`LocalDecisionProvider.couldMatch`, the on-device matcher's own test, so a
dropped macro scores 0 on device and can never win.
`VoiceVocabularyTrimTests` pins the choice AND the confidence over a corpus
that includes Grux's last reply in the state; red-proven by filtering on the
first line only (a keyless answer flipped from `macro:overlay_on`) and by
dropping the phrase check (the two-letter `tv` macro, which scores 0.95 on
device, was lost).

### P-R-9 follow-up: the AirPods path, live, 10:52

The operator moved the output back to the AirPods Max at 10:52:44. Grux, from
`wake.log`: `ambient: paused - output changed`, `listening mic: Listening moved
off the operator's AirPods Max to MacBook Pro Microphone`, `ambient: VPIO BYPASSED
(output is Bluetooth, the mic cannot hear it)`, `ambient: engine up
native=48000Hz ch=1 on MacBook Pro Microphone`, `ambient: hearing 2.1s of
audio`. That is the whole P-R-9 path working on the installed build.

The AirPods nonetheless read `Current SampleRate: 24000`, the call profile. To
find out whose that is, Grux was quit completely for six seconds: the AirPods
STILL read 24000. So another process holds their microphone. Fathom's
`FathomAudioMonitor` is running and is the likeliest holder; this shell cannot
see per-process audio use, so which one is not proven. Grux was relaunched.

## P-R-5: attention on the decision engine, 2026-09-21

**Suite: 2816 executed, 11 skipped, 0 failures** (`1d5f72e` on lane/P-R-5, not
installed; the operator builds). The 11 skips are this machine: registrar
credentials present, the Accessibility grant held, no release build in a lane
worktree.

Four judgments, each with its hand-rolled logic kept as the floor and as the
whole keyless behaviour. Keyless means nothing is asked: no call, no ledger
row. On device (or on a provider failure) an answer never gets a vote.

| surface | type | floor (and keyless) | what the engine may do | cache key |
|---|---|---|---|---|
| `mail.needsYou` | noul `needs` | `MailNeedsYou.needsYou` heuristic | take a message out of the badge below 0.3 | message id; the probability is stored on the message |
| `notify.triage` | choice `action` over interrupt, batch, silent | rules, category row, Haiku seam | at 0.7 or more, replace the category row for that one notification; blockers still interrupt, quiet hours still hold | the notification's words, case and spacing folded |
| `email.classify` | choice `category`, choice `urgency`, noul `review`, one call | the old combined classify-and-draft text call | at 0.6 or more on the category, classify; drafting stays on the text model | exactly what the engine read (sender, subject, message), so a message re-swept while unread is not re-asked and a follow-up with new words is |
| `focus.drift` + `focus.interrupt` | two nouls, ONE event | FocusWatcher drift past the cooldown is a nudge | hold a nudge back (drift under 0.4, moment under 0.35), never cause one | one event per nudge candidate; a hold spends the cooldown |

**Calibration, live provider, invented fixtures only, one attempt per call, 61
calls.** The grux-ecosystem key read from the Keychain at run time, model
resolved to `jev-1.13.0`, `X-Title: Grux OS: decisions (P-R-5 calibration)`.
These are the fixtures the wording was written against, so they are in-sample;
there is no held-out set yet.

#### mail.needsYou (noul `needs`)

| fixture | expected | answer | ms | in tok |
|---|---|---|---|---|
| colleague-signoff | high | 0.98 | 406 | 415 |
| shipped-receipt | low | 0.08 | 389 | 418 |
| invite-accepted | low | 0.08 | 384 | 401 |
| friend-dinner | high | 0.97 | 374 | 406 |
| invoice-due | high | 0.92 | 356 | 432 |
| new-signin | low | 0.09 | 409 | 414 |
| recruiter-cold | low | 0.70 | 353 | 421 |
| contract-sign | high | 0.97 | 400 | 407 |
| office-closed-fyi | low | 0.06 | 371 | 403 |
| thanks-got-it | low | 0.05 | 349 | 400 |
| customer-damaged | high | 0.97 | 361 | 411 |
| review-requested | high | 0.97 | 374 | 419 |
| mention-confirm | high | 0.94 | 335 | 411 |
| password-reset | low | 0.08 | 361 | 406 |

#### notify.triage, wording 1 (choice `action`)

| fixture | expected | answer | ms | in tok |
|---|---|---|---|---|
| apple-rejected | interrupt | interrupt 0.97 | 386 | 449 |
| domain-check-autorenew | silent or batch | batch 0.45 | 335 | 449 |
| domain-expiring-3d | interrupt | interrupt 0.95 | 353 | 460 |
| schedule-finished | batch | batch 0.87 | 594 | 451 |
| schedule-failed | interrupt | interrupt 0.52 | 357 | 449 |
| switched-focus | silent or batch | interrupt 0.85 | 343 | 447 |
| api-key-ok | silent | silent 0.93 | 326 | 439 |
| ios-publish-attention | interrupt | interrupt 0.90 | 442 | 446 |
| disk-almost-full | interrupt | interrupt 0.99 | 601 | 454 |
| weekly-summary | batch | batch 0.99 | 418 | 443 |
| backup-clean | silent | batch 0.54 | 365 | 444 |
| credit-low | interrupt | interrupt 0.96 | 474 | 449 |
| support-drafts | batch | batch 0.73 | 438 | 447 |
| phase-build | batch or silent | batch 0.93 | 412 | 449 |

#### notify.triage, wording 2, SHIPPED

| fixture | expected | answer | ms | in tok |
|---|---|---|---|---|
| switched-focus | silent or batch | interrupt 0.65 | 373 | 469 |
| backup-clean | silent | silent 0.84 | 537 | 466 |
| schedule-failed | interrupt | interrupt 0.86 | 386 | 471 |
| domain-check-autorenew | silent or batch | interrupt 0.62 | 362 | 471 |
| api-key-ok | silent | silent 0.87 | 337 | 461 |
| apple-rejected | interrupt | interrupt 1.00 | 380 | 471 |

#### email.classify, refund wording 1

| fixture | expected | category | urgency | review | ms | in tok |
|---|---|---|---|---|---|---|
| rash-refund | refund/high/high | refund 1.00 | high 1.00 | 0.96 | 412 | 636 |
| where-order | shipping/normal/low | shipping 1.00 | normal 0.99 | 0.22 | 392 | 637 |
| sensitive-skin | product/normal/mid | product 1.00 | normal 0.94 | 0.68 | 391 | 630 |
| love-it | other/low/low | other 0.99 | low 1.00 | 0.08 | 359 | 624 |
| chargeback-threat | refund/high/high | shipping 0.37 | high 1.00 | 0.97 | 496 | 638 |
| ship-canada | shipping/normal/low | shipping 1.00 | normal 1.00 | 0.12 | 394 | 627 |
| change-address | shipping/normal/low | shipping 1.00 | high 0.26 | 0.42 | 502 | 646 |
| partnership | other/low or normal/low | other 1.00 | normal 0.99 | 0.34 | 360 | 633 |
| delivered-missing | shipping/high/mid | shipping 1.00 | high 0.89 | 0.66 | 345 | 642 |
| cancel-sub | other/normal/low | other 1.00 | normal 0.99 | 0.24 | 380 | 628 |

#### email.classify, refund wording 2, SHIPPED

| fixture | expected | category | urgency | review | ms | in tok |
|---|---|---|---|---|---|---|
| rash-refund | refund/high/high | refund 1.00 | high 1.00 | 0.96 | 827 | 650 |
| where-order | shipping/normal/low | shipping 1.00 | normal 0.99 | 0.22 | 408 | 651 |
| chargeback-threat | refund/high/high | refund 0.86 | high 1.00 | 0.97 | 468 | 652 |
| change-address | shipping/normal/low | shipping 1.00 | high 0.25 | 0.35 | 526 | 660 |
| delivered-missing | shipping/high/mid | shipping 1.00 | high 0.91 | 0.64 | 521 | 656 |

#### focus.drift + focus.interrupt, one shared call

| fixture | expected | drift | moment | ms | in tok |
|---|---|---|---|---|---|
| cat-videos | drift high / moment high | 0.85 | 0.62 | 530 | 585 |
| wwdc-lists | drift low | 0.09 | 0.59 | 418 | 595 |
| stackoverflow | drift low | 0.09 | 0.67 | 365 | 567 |
| zoom-meeting | moment low | 0.32 | 0.10 | 316 | 601 |
| twitter-feed | drift high / moment high | 0.70 | 0.67 | 317 | 580 |
| slack-about-work | drift low | 0.10 | 0.64 | 412 | 575 |
| shopping | drift high / moment high | 0.81 | 0.67 | 372 | 573 |
| meet-client | moment low | 0.15 | 0.09 | 336 | 566 |
| keynote-present | moment low | 0.05 | 0.11 | 306 | 553 |
| messages-short-break | drift mid or low | 0.31 | 0.65 | 358 | 534 |
| netflix-phone | drift high / moment low | 0.75 | 0.11 | 365 | 607 |
| figma-design | drift low | 0.06 | 0.70 | 392 | 577 |
- mail: 14 calls, p50 374 ms, max 409 ms, mean input tokens 411
- notify: 14 calls, p50 412 ms, max 601 ms, mean input tokens 448
- notify2: 6 calls, p50 380 ms, max 537 ms, mean input tokens 468
- email: 10 calls, p50 392 ms, max 502 ms, mean input tokens 634
- email2: 5 calls, p50 521 ms, max 827 ms, mean input tokens 653
- focus: 12 calls, p50 365 ms, max 530 ms, mean input tokens 576
- total calls: 61

**Calls per day, from the operator's volumes.** Input tokens per call measured
above: mail about 410, notification about 470, email classify about 650, the
coach event about 580. Mail: a one-time backlog pass of about 50 (the floor
counts about 50 of the 245 cached), then one per new message the floor counts,
roughly 10 to 20 a day. Notifications: one per distinct free-text notification,
roughly 5 to 15. Email classify: one per new support email, 0 to 20. Coach: at
most one per cooldown while the vision verdict says drift (180 s in normal
mode), roughly 10 to 20 on a working day. About 30 to 75 calls, 15K to 40K input
tokens, under $0.002 a day, about $0.05 a month of the $5.00 credit.

**Red-proven, each planted, failed, restored and `diff`ed byte-identical:**
mail keyless guard removed (keyless test: 2 ledger rows); mail cache ignored
(a judged message re-asked, 4 calls for 2); triage keyless guard removed
("keyless would defer delivery into a Task"); triage confidence floor removed
(a 0.62 interrupt was used); classify keyless guard removed (a keyless ledger
row); classify confidence floor removed (a 0.37 category trusted); classify
cache removed (a re-swept message asked twice); coach
keyless guard removed (a keyless ledger row); coach split into two calls ("the
tick paid 2 round trips", ledger rows `focus.drift`, `focus.interrupt`);
triage in-flight share removed (two identical notifications in one round trip
paid 2 calls, found by an independent review of the lane diff and fixed).

**Not verified here:** nothing ran in the live app. The lane does not build or
install; each surface's first live ledger rows are the operator's to read.

## P-R-6: work, memory and agents, 2026-09-21

**Calibration, live provider** (`/v1/systemone`, jev-latest resolved to jev-1.13.0,
grux-ecosystem key read from the Keychain at run time, never pasted). Invented
fixtures only. One attempt per call, no retries. 73 calls in all. The tables below are the
SETTLED wording, sent in the exact wire shape the app sends; earlier rounds are summarised
under each one.

**task.priority + project.attribution** (one call per new task, both questions on it,
names namespaced as a shared event sends them; about 590 input tokens each):

| new task | expected | priority score (conf) | project (conf) | ms |
|---|---|---|---|---|
| Fix the crash when the Trailhead map opens offline, reviewers flagged it for tomorrow's release | now, Trailhead iOS | 1.99 (0.99) | Trailhead iOS 0.96 | 455 |
| Pick a new font pairing for the bakery menu page | later or next, Harbor Bakery Site | 0.01 (0.99) | Harbor Bakery Site 0.96 | 344 |
| Pay the quarterly estimated tax, due tomorrow | now, Taxes 2026 | 2.00 (1.00) | Taxes 2026 0.92 | 355 |
| Add a watering reminder column to the planner | later or next, Garden Planner | 0.01 (0.99) | Garden Planner 0.69 (under 0.70, left blank) | 348 |
| Send the bakery owner the staging link before their 4 PM call today | now, Harbor Bakery Site | 2.00 (1.00) | Harbor Bakery Site 0.95 | 380 |
| Renew the bakery site's domain, it lapses in three weeks | later or next, Harbor Bakery Site | 0.82 (0.67) | Harbor Bakery Site 0.98 | 336 |
| Refactor the settings screen | later or next, none | 0.01 (0.99) | none 0.85 | 394 |
| Book a haircut | later or next, none | 0.01 (0.99) | none 1.00 | 389 |
| Renew the car registration, it expires tomorrow | now, none | 2.00 (1.00) | none 1.00 | 352 |

Round 1 (10 calls, same priority wording, a stricter project wording and bare bucket
descriptions): priority 10 of 10 in band; project 9 of 10 right but at 0.48 to 0.72, so only
2 of 5 real attributions cleared 0.70. Describing each bucket by the tasks already in it
fixed that. One more call probed the score answer's shape: `score` is the expected level
index with a separate `confidence`.

**project.attribution for logged decisions** (one call per extraction pass, 3 records each):

| decision | expected | answer | call |
|---|---|---|---|
| Switch the bakery site to the lighter menu layout | Harbor Bakery Site | Harbor Bakery Site 0.99 | 371 ms, 921 in |
| Use offline map packs instead of caching tiles by hand | Trailhead iOS | Trailhead iOS 0.71 | same call |
| Stop drinking coffee after 2 PM | none | none 1.00 | same call |
| File the tax extension rather than rushing the return | Taxes 2026 | Taxes 2026 0.96 | 396 ms, 901 in |
| Take Friday off | none | none 0.97 | same call |
| Move the seed calendar to a weekly view | Garden Planner | Garden Planner 0.96 | same call |

**meeting.moment** (one call per summary, one choice per listed item, the transcript as state):

| meeting | item | expected | answer | call |
|---|---|---|---|---|
| menu launch | Use Northside Print for the menus | decision | decision 1.00 | 361 ms, 1,333 in |
| | Send the final PDF to the print shop by Wednesday | action item | action_item 0.98 | |
| | Update the website prices tonight | commitment | commitment 0.97 | |
| | Check the gluten free label fits on the card (asked of Me, accepted) | commitment | commitment 0.88 | |
| | Keep the launch on the fifth | decision | decision 0.99 | |
| | Order new aprons for the staff | not said | not_said 1.00 | |
| report deadline | Send a draft of the report by Thursday | commitment | commitment 1.00 | 366 ms, 938 in |
| | Pull the numbers from the dashboard | action item | action_item 1.00 | |
| | Drop the survey section | decision | decision 1.00 | |
| | Schedule a follow up with the client | not said | not_said 1.00 | |
| app release | Hold the release until the crashes are fixed | decision | decision 0.98 | 415 ms, 1,095 in |
| | Fix the login crash | action item | action_item 0.99 | |
| | Fix the photo picker crash | action item | action_item 1.00 | |
| | Tell the reviewers the release is delayed a day | commitment | commitment 0.96 | |
| | Write the release notes | not said | not_said 1.00 | |

Round 1 (3 calls) was 14 of 15: the accepted request read as action_item 0.54, under the
threshold, so it would have shown nothing. A 33,005 character transcript (the menu meeting
plus filler) was accepted at 560 ms, 10,333 input tokens, same six answers.

**approvals.risk** (one call per new item, the item's own description as state):

| pending action | expected | score (level) conf | flagged | ms |
|---|---|---|---|---|
| Post a Slack message to #general | high | 1.98 (high) 0.97 | yes | 384 |
| Run tool shell_start, no input | low or medium | 1.26 (medium) 0.24 | no | 347 |
| Buy the icon pack, amount_cents 1200 | high | 1.96 (high) 0.94 | yes | 961 |
| You said: mute the microphone | low | 0.04 (low) 0.94 | no | 527 |
| Run tool files_delete | high | 2.00 (high) 0.99 | yes | 593 |
| Run a Claude Code session: advance the onboarding checklist | medium | 0.89 (medium) 0.44 | no | 510 |
| Send an email to the bakery owner with the staging link | high | 1.99 (high) 0.99 | yes | 528 |
| Run tool calendar_create_event | low or medium | 1.00 (medium) 0.54 | no | 970 |
| Push the workday log to Notion | high | 2.00 (high) 0.99 | yes | 515 |
| Run tool set_volume | low | 0.26 (low) 0.61 | no | 504 |
| shell_start, input `rm -rf ~/Downloads/old-builds` | high | 1.95 (high) 0.93 | yes | 394 |
| shell_start, input `npm run build` | low or medium | 0.78 (medium) 0.65 | no | 375 |
| calendar_create_event, input a dentist appointment | low or medium | 0.80 (medium) 0.49 | no | 329 |

Round 1 (10 calls, "high: spends money, reaches other people, deletes data or cannot be
undone"): 8 of 10 in band, only 3 of the 5 high items flagged (the $12 spend at 0.55, the
Notion push read medium).

**agent.worthStarting** (one noul before a LIVE goal-pursuit job; held when "no" reaches 0.70):

| plan | expected | p(worth) | result | ms |
|---|---|---|---|---|
| Advance: Offline map cache, concrete goal in a named project | yes | 0.86 | start | 353 |
| Improve the app, "make the app better in every way" | no | 0.36 | start (left to the floor) | 358 |
| Reply to the 12 unread emails | no | 0.22 | HOLD | 319 |
| Offline map cache again, while the same job is running | no | 0.23 | HOLD | 358 |
| Advance this goal one concrete step (the keyless planner's pick) | yes | 0.63 | start | 347 |
| Approve the 3 items waiting in the approval queue | no | 0.22 | HOLD | 341 |
| Write tests for the receipt parser, named project | yes | 0.87 | start | 379 |
| Build a crypto trading bot, advances no signal | no | 0.17 | HOLD | 339 |
| Wire the Apple Pay button, another job running | yes | 0.71 | start | 372 |

Round 1 (9 calls) put every plan on the same side of 0.5. As the app sends it, with the held
item's `approvals.risk` on the same call (its own state in front of its own instructions):
worth 0.86, 0.20, 0.25 against 0.86, 0.22, 0.23 alone, and the risk read high at 0.98 for the
email job and medium for the two code jobs, 394 to 499 ms for 642 to 702 input tokens.

**Tests:** `WorkJudgmentTests`, 23 tests, every one red-proven: 30 plants over four batches,
one per guarded line, each batch built and run, then every planted file restored and compared
byte for byte with its backup; the tracked diff was byte-identical before and after all four
batches. The one-call rule is enforced where two judgments share an event: planting the
project question as its own `decide` inside the open task event failed
`test_task_priorityAndProjectShareOneCall` on the call count AND on
`batchViolations == ["project.attribution"]`.

## Phase R lanes merged, and what showed up live, 2026-09-21

**Suite: 2869 executed, 10 skipped, 0 failures** after merging P-R-5, P-R-6,
P-R-7 and P-A10-2 onto P-R-4 and wiring `TaskJudgments.shared.start()`. An
independent review of the aggregate diff found no confirmed bug (it read the
files at HEAD rather than a literal diff, and said so).

Live on the running app:

- **Mail that needs you: 53 to 17.** Opening Mail started the sync, which
  logged `inboxSync: synced 1 account(s), 0 new, 53 judged for needs-you`; the
  ledger took 53 `mail.needsYou` rows at p50 363 ms and 427 input tokens each
  (the whole backlog, once, for under a tenth of a cent). The rail badge read
  53 on the heuristic floor and 17 after (`mail-badge-after-judging.png`).
  Mail polling still starts only when the Mail tab is shown, which is older
  behavior and limits how fresh the count is; that belongs to Phase D.
- **The which-app question in real room talk:** "We just kind of want to open
  it up to you guys" put it on the call (3,469 input tokens against 2,149),
  answered none at 1.00 and was ignored. That is correct but wasteful, so
  the question now needs its verb in the first four words (`7d7e066`).
- **The Usage card** in Settings, Models (`usage-card-live.png`). The capture
  predates `d502884`, so its last line still reads "Heard: question, right?",
  the gate's lead-in leaking into the copy, which is what that commit fixed.
  The expanded Focus pill floats over the card's right column and hides two
  values; that is the pill's placement over Grux's own window, noted for
  Phase C and D rather than widened into this packet.
- **The trigger table** answers from its new file: `fire-open-tab
  settings:usage` acked.

## P-R-10: the latency table, per gate, from the ledger, 2026-09-21

Measured the same way for both columns: `scripts/decision-latency-table.py
--before-end 2026-09-21T14:33:00Z --after-start 2026-09-21T14:50:00Z` over the
operator's own `decisions.jsonl`. Before is every decision before P-R-1 was
installed; after is every decision since P-R-2 was installed. This is also
P-A9-7's table and the one the 3.0 release notes carry.

**Before (every decision before 2026-09-21T14:33:00Z)**

| gate | provider | calls | p50 | p90 | input tokens (median) | cost per call |
|---|---|---|---|---|---|---|
| voice | Jev | 742 | 441 ms | 538 ms | 4,460 | $0.0002 |
| voice | on device | 60 | 4 ms | 7 ms | 0 | nothing |
| jax.gate | Jev | 17 | 414 ms | 522 ms | 454 | under $0.0001 |
| jax.gate | on device | 14 | 0 ms | 0 ms | 0 | nothing |

**After (every decision since 2026-09-21T14:50:00Z)**

| gate | provider | calls | p50 | p90 | input tokens (median) | cost per call |
|---|---|---|---|---|---|---|
| mail.needsYou | Jev | 53 | 363 ms | 430 ms | 427 | under $0.0001 |
| voice | Jev | 51 | 392 ms | 453 ms | 2,241 | under $0.0001 |
| voice+app.intent | Jev | 2 | 404 ms | 462 ms | 2,825 | $0.0001 |
| voice+chat.intent | Jev | 1 | 341 ms | 341 ms | 2,298 | under $0.0001 |

What the table says, gate by gate:

- **voice** (every chunk the room produces): p50 441 ms to **392 ms**, p90 538
  to **453 ms**, input 4,460 to **2,241 tokens**, cost per call halved. The
  whole difference is P-R-2's vocabulary trim; P-R-1 did not change a lone
  voice call on the wire, by design.
- **A spoken request that reaches Chat** (voice + chat.intent): before, two
  sequential calls, the voice call and then Chat's own (the live probe measured
  728 to 912 ms for the pair); after, ONE call, `voice+chat.intent` at 341 ms.
- **voice + app.intent** (new in P-R-4): 404 ms p50 for both questions on one
  call.
- **mail.needsYou** (new in P-R-5): 363 ms p50, 427 tokens, asked once per
  message, never per render.
- **jax.gate, chat.intent alone, shell.destructive**: no rows in the after
  window, because no tool dispatch, typed PIM request or approved shell replay
  happened in it. Their wire shape is unchanged by P-R-1 (a lone gate is
  identical to its old direct call), so their before numbers stand: jax.gate
  414 ms p50 on Jev.
- **On device**: 4 ms p50 before, and a keyless install is unchanged after,
  pinned by the parity tests rather than by live rows (this install has a key).

## P-R-3 closed: every credit-backed key, Anthropic added, 2026-09-21

**What the lane merged (`e2fbc03`).** One `CreditState` per provider in
`credits.json` under `Persistence.supportDir`, one `CreditMonitor` that every
provider reports to, and one `CreditNotice` that feeds both the notification
and the Usage card's single status line, so the two cannot describe one outage
differently. An episode runs from the first out-of-credit response to the next
success; the person is told once per episode, and only if a call on that key
had succeeded before (a keyless install, or a key that never worked, hears
nothing).

**Known from the response, never guessed**, provider by provider
(`Credits/CreditSignature.swift`, each with its source URL and the date checked):

| key | detector | source |
|---|---|---|
| OpenRouter | 402 with `error.code` 402, except `openrouter_in_flight_budget` and `weight_exceeds_budget` (a positive balance) | documented, errors and limits pages |
| ElevenLabs | 402 `insufficient_credits` or `payment_required`; 400 or 401 with `detail.status` `quota_exceeded` | documented, two pages |
| Anthropic (this commit) | 400 `invalid_request_error` whose message says "credit balance is too low", inside the documented error envelope | observed on this install (2026-08-23, 563 calls; 358 more in the week before today); the docs give an empty balance no status of its own |
| Jev | OFF | not documented (docs list 401, 422, 429, 529; OpenAPI lists 200, 422) and never observed |
| Replicate | OFF | not documented (no 402 in the HTTP reference or OpenAPI) and never observed |

Anthropic's documented 402 `billing_error` ("an issue with your billing or
payment information"), its 400 at a spend limit the person set, and its 429
spend cap all answer false: none of them is an empty balance. Every
unrecognised failure is logged once per provider and status per run, with the
body redacted, which is how the Jev and Replicate shapes will be captured the
day they happen.

**Anthropic is wired at all five `ClaudeClient` paths** (`complete`,
`completeCached`, `completeVision`, `completeWithTools`, and the chat stream),
successes and failures alike. `ProviderHealth` keeps its own breaker for
standing background loops down; the credit monitor is the person-facing half.

**Suite: 2932 executed, 10 skipped, 0 failures** with everything below in
it. **Tests.** `CreditStateTests` is 20 tests, 3 of them new today:
`test_anthropicKnowsAnEmptyBalanceOnlyFromItsOwnSentence`,
`test_anthropicClientKnowsItsOwnOutOfCredit` (the real `ClaudeClient` on a
stubbed session: success, seven non-credit failures and a timeout mark
nothing, the empty balance marks it once across three paths, an opened chat
stream ends the episode, and the stream's own empty balance starts a new one),
and `test_everyClaudeFailureReportsItsCredit`. Red-proven four ways, each
restored and `diff`ed byte-identical:

| planted | result |
|---|---|
| detector ignores the sentence | 3 failures, "a malformed request read as out of credit" |
| chat stream failure stops reporting | 3 failures, "Claude failure path 4 does not report its credit" |
| `complete()` success stops reporting | 4 failures, "a Claude success was not reported" |
| notice loses its refill URL, then loses "focus checks" | 1 failure each |

**Criterion 6, mapped.** Detected from the provider's response: the table
above. One notification and one Usage card line:
`test_exactlyOneNoticePerEpisode_andASuccessEndsIt`,
`test_theUsageCardLineAppearsWhenACreditRunsOutAndGoesAwayOnRecovery`. Only for
someone with prior successful calls: `test_noNoticeWithoutAPriorSuccess`,
`test_aKeylessInstallSeesNothing`. The same mechanism for every credit-backed
key: five providers, one monitor, one notice type.

**Live, on the running app (launched 1:07 PM).** `credits.json` reads
`jev` and `openrouter` with `hasSucceeded: true`, written by real calls: the
success half is proven on the running app. **NOT PROVEN live: an out-of-credit
episode on any key.** None is out right now, and the one that was, Anthropic,
is no longer on chat's route: chat goes to OpenRouter
(`deepseek/deepseek-v4-flash-0731`), and every path still pinned to Anthropic
(focus checks during a focus session, Compare, Design Studio critiques, diff
reviews, the Test Key button) needs a person to start it.

## What the live check turned up, 2026-09-21

**1. The chat log named the wrong model.** `chat: sending 37 chars to
claude-haiku-4-5-20251001 (keylen=108)` printed `config.model` and the
Anthropic key's length whatever the route was, so an OpenRouter turn read as a
Claude turn (it misled this session into believing Anthropic chat was failing
today). The line now names nothing, and the route is logged where it is
resolved: `chat stage: context assembled at +0.36s, routed to <model>`.

**2. Grux went deaf after speaking, and stayed deaf.** Twice today, the
ambient restart after Grux spoke came up with no audio: 11:42 AM (two engine
starts 2.4 seconds apart) and 1:08 PM (`engine.start()` blocked 2.8 seconds
with voice processing on). Both times the two-second check logged `DEAF` and
then every level reading stayed at `rms=0.0000` for as long as the app ran
(over four minutes at 1:08 PM), because the check only logged. Now a deaf start
restarts after 1 second, then 2, and after two restarts gives up visibly
(`AmbientState.error`: "The microphone is not sending any sound. Turn listening
off and on again.") rather than claiming to listen. The rule is a pure
function, `AmbientListener.deafStartAction`, with 3 tests in
`DeafStartRecoveryTests`, red-proven three ways (never restarting: 3 failures;
the check only logging again: "a deaf start no longer restarts"; the restart
resetting its count: "the restart starts a fresh count, so the bound never
holds"). The root cause of the deaf start, voice processing re-pairing while
the speech output is still releasing the device, is not fixed; this makes it
recover.

Verified on the running app, twice. At 1:43 PM Grux said "ready"; the resume
after it came up deaf (`DEAF ... restarting in 1s (restart 1 of 2)`), restarted
at 1:43:50 PM and logged `hearing 1.4s of audio` two seconds later, with
non-zero levels. The relaunches at 1:43 PM and 1:48 PM showed the same thing
at launch: the first start took 3 seconds and heard nothing, the restart took
45 ms and heard 2.0 seconds of audio.

**4. The log named the speakers as the microphone.** With voice processing on,
the input unit's current device is the output it pairs with, so every such
start logged `engine up ... on MacBook Pro Speakers` and `DEAF, no audio from
MacBook Pro Speakers`. `MicDevices.boundInputName` now reports the default
input when voice processing is on; live at 1:48 PM: `engine up native=48000Hz
ch=7 on MacBook Pro Microphone (voice processing)`.

**3. The suite hung for 19 minutes on a locked screen.**
`PermissionRefreshTests.testRefreshingTheObservationActuallyWritesTheKey`
called the real `AEDeterminePermissionToAutomateTarget`, an Apple Events round
trip to TCC that blocks while the login window is in front. The resolver now
takes a `probe`, the test passes a stub and asserts every target was asked,
and a planted probe that is ignored fails it. The app only asks while the
Automation card is on screen, with somebody at the Mac.

**5. Mail printed a 24 hour clock.** The live Mail capture
(`docs/superpowers/evidence/2026-09-21-folds-and-today/compose-in-mail.png`)
stamps the day's messages `08:54`, `10:00`, `12:07`, and the Security log did
the same (`MMM d HH:mm`). Both now go through `TodayModel.clock` (`8:54 AM`).
`NoTwentyFourHourClockTests` (3): the Mail list and detail, the Security log,
and a scan that no `*View.swift` file formats `HH:mm` at all (it reads over 50
view files, so a scan that silently found none would fail). Red-proven twice:
Mail back on `HH:mm` fails 2 ("08:54" is not "8:54 AM"), the Security log back
on it fails 3. Data formats outside views (ISO strings, IMAP date parsing, what
a model reads) are not rendering and are left alone. Live after the 2:24 PM
install, captured by the sweep: `12:16 PM`, `12:07 PM`, `11:15 AM`, `10:00 AM`
(`docs/superpowers/evidence/2026-09-21-folds-and-today/mail-twelve-hour.png`).

## The operator could not be heard, and what eqMac has to do with it, 2026-09-21

**Reported by the operator, 2:27 PM:** music quality better in headphones,
but talking reached nothing, through the orb or the chat mic, while the chat
header read ARMED and LISTENING. And: the audio issue correlates with eqMac.

**What the logs say happened.** At 2:24 PM the new build started ambient with
voice processing (output: built-in speakers). All three starts were deaf, and
the retry policy of the time gave up after two restarts. Core Audio logged the
cause on each one, in Grux's own process: `HALC_ProxyIOContext::_StartIO():
Start failed - StartAndWaitForState returned error 35`, at 2:24:30, 2:24:34 and
2:24:40 PM, plus `HALB_IOThread::_Start: there already is a thread` on the
first. `engine.start()` returned normally every time, so only the two-second
check knew. After giving up, every surface kept reading ARMED, and the orb tap
the operator tried next muted Grux (2:27:25 PM, `mic: MUTED (user tapped orb)`).

**The mic itself was fine.** Probed at 2:33 PM from a fresh process, two
seconds each: plain capture 96,000 frames; voice processing 91,200 frames
(9 channels, start 0.64 s); plain again 96,000. Every voice processing start
Grux logged as deaf today had come up with 7 channels, every healthy one
with 9. So the fault is Core Audio intermittently refusing to start the voice
processing IO, and plain capture from the same mic works when it does.

**eqMac, audited.** eqMac 1.8.12 (1.9.1 skipped), its HAL driver 2.6.0
(`/Library/Audio/Plug-Ins/HAL/eqMac.driver`, hosted by pid 525 since boot on
Sep 4) and its privileged helper (a RunAtLoad launch daemon) are installed.
The eqMac APP last ran this morning: the system log lists it alive at
8:00 AM and its pid was reused by other programs by 9:50 AM. So it was not
running during any deaf start today. Its driver host logged nothing during the
2:24 PM failures (its only lines today are property exceptions at 8:23 and
8:51 AM). With the app quit, no eqMac device exists: Core Audio lists exactly
two devices, the MacBook Pro Microphone and Speakers.

What eqMac DOES do while it runs, and why the operator is right to tie it to
the audio: it makes its own virtual device the default output and plays
through the device chosen inside it (its saved list includes the AirPods Max).
Grux read any virtual output as "unknown", and unknown keeps voice processing
ON, so AirPods behind eqMac got voice processing and its communications path,
the music-quality loss P-R-9 fixed only for AirPods reached directly.

**Fixed, each red-proven:**

1. **A virtual output is read through to the real device it plays on**
   (`VoiceProcessingPolicy.resolve`): exactly one real output device running
   is where the sound goes; none or several stays unknown. eqMac into the
   AirPods reads as Bluetooth, so voice processing stays off.
2. **A deaf voice processing start marks `VoiceProcessingRefusal`**, and every
   start (ambient and the chat mic) skips voice processing for 10 minutes
   after one, so the restart runs on plain capture, which works. The chat
   mic marks it too when a voice processing recording received no buffer at
   all (a quiet room still delivers buffers).
3. **Retries run for about a minute and a half** (1, 2, 10, 30, 60 seconds)
   before giving up, instead of two.
4. **NOT HEARING is a word on every surface** that shows the tell (rail,
   chat header and live rail, menu bar, HUD, Today, the orb palette), fed by
   `MicHealth`, which publishes only on a transition so the rail does not
   redraw at audio rate. It shows from the second deaf start in a row.
5. **An orb tap while not hearing tries the mic again** instead of muting.

Tests: `DeafStartRecoveryTests` (5, rewritten), `VoiceProcessingThroughEqMacTests`
(6), `NotHearingTellTests` (5). Red-proven five ways, each restored and `diff`ed
identical: a virtual output read as unknown again (4 failures); the tap muting
while not hearing ("a tap on a listener that hears nothing muted it"); a deaf
start no longer marking the refusal; the rail not reading mic health
("LaunchRootView.swift shows the tell without knowing whether the mic is
heard"); the policy ignoring the refusal (2 failures).

**Verified on the running app, 2:47 PM install, signed in, built-in
speakers:** the voice processing start was deaf again (7 channels), and Grux
logged `voice processing started and delivered nothing; listening without it
for 10 minutes`, restarted one second later with `VPIO BYPASSED (voice
processing would not start a moment ago...)` and logged `hearing 2.0s of audio
from MacBook Pro Microphone` 3.4 seconds after the first start, with speech
registering (`voiced=Y`) five seconds later. Suite: **2945 executed, 10
skipped, 0 failures.**

**NOT PROVEN live: the eqMac path.** eqMac is not running and this session did
not start it, because it changes the operator's system output. With eqMac
running and the AirPods chosen in it, Grux should log `audio: the default
output eqMac is virtual; it plays through <AirPods>, read as Bluetooth` and
`VPIO BYPASSED`.

**Not fixed: why Core Audio refuses the voice processing IO.** The trigger is
unknown. The refusals began at 11:42 AM after a burst of fast restarts, and
they got more frequent through the afternoon. If they persist, a restart of
`coreaudiod` clears Core Audio's state, but that needs the operator's admin
password.


## P-H-1: the suite writes nowhere real, `~/.grux` included, 2026-09-21

**`Persistence.gruxDir` is the one place `~/.grux` is built.** Under test it
is `.grux` inside the suite's per-process scratch directory. Measured before
the change: 107 hand-built sites in about 60 files (the row had recorded 54),
in four shapes. A codemod rewrote 103 sites in 60 files; the other 4 were
display copy and `IOSDispatcherV2`'s project-root `.grux` folder, which is a
project's own folder and not this one. `IdeaQueue`'s public initializer now
takes an optional folder, because a public default cannot reach the internal
`Persistence`.

**The guard, and the bug it caught on its first run.**
`GruxDirIsBuiltOnceTests` scans every Swift file in `Sources/Grux` (over 500)
for the four shapes. It carries a positive control: it must find the
definition inside `Persistence.swift`, or it fails as broken. That control
failed on the first run, and it was right: the codemod had rewritten the
definition itself into `return Persistence.gruxDir`, which is infinite
recursion in the shipping app, and only the scan noticed. Also red-proven by
planting one hand-built path back (`KnownProjects.swift`), and
`SuiteWritesNowhereRealTests.test_theDotGruxFolderIsNotTheOperators` by
making `gruxDir` ignore the test flag. `AutonomyLedgerTests` used to write a
corrupt ledger into the operator's REAL `~/.grux/jax/autonomy-ledger.json` on
purpose; it now corrupts the scratch copy.

**Proven on the operator's machine.** A listing of every file in `~/.grux`
(2,283 files, size and modification time) before and after a full suite run,
3:02:53 to 3:05:20 PM, with Grux running: 0 added, 0 removed, 3 changed, and
all three are the running app (`ambient/screentime-2026-09-21.ndjson`, the
10-second Screen Time watcher; two `focus/ttys*.activity.jsonl`, terminal
focus for this session's shells). None of the five stores the row named was
touched, and no quarantine file appeared. **Suite: 2951 executed, 10
skipped, 0 failures.** Out of scope, named: the `GruxShellCore`,
`GruxAgentCore` and CLI targets cannot see `Persistence` and build their own
paths.

**The app still lives in the real folder** (3:09 PM install): four
`fire-open-tab` switches through `~/.grux` were acknowledged, and Today read
the Jax approvals ("38 approvals waiting on you"), terminal focus (the task
in focus, by name) and the task stack from it
(`docs/superpowers/evidence/2026-09-21-folds-and-today/today-after-ph1.png`).

## G-R: the Phase R gate, 2026-09-21

Each acceptance criterion of the backend decision record
(`questionnaires/_decisions/grux-backend-jev-rethink.md`, kept outside this repository), with the
artifact that proves it.

**1. One Jev call per judged event, and a test that fails if a gate opens its
own round trip when a batched one was available.** `DecisionEvent` (P-R-1).
`DecisionEventTests.test_aGateThatOpensItsOwnCallInsideAnEventIsCaught`
(`batchViolations` names the gate), `test_aSpokenRequestThatGoesToChatPaysOneCall`,
`test_aBatchOfNQuestionsIsOneCallAndOneLedgerRowNamingEveryGate`,
`test_aLoneGateIsIdenticalOnTheWire`. Live: a spoken request that reaches Chat
is one `voice+chat.intent` call (P-R-10 table).

**2. Every decision point on the engine, or a recorded reason.** The spec's
twelve (design spec section 5) and the record's fourteen new ones, which
overlap in eight places, so 18 distinct points:

| decision point | in the spec | new in the record | on the engine as | where |
|---|---|---|---|---|
| ambient command versus chatter, with slots | yes | (done before) | `voice`; slots stay on regex and Jev judges the plan they fill (`chat.intent` PIM questions) | `VoiceCommandRouter`, `IntentClassifier` |
| intent routing in Chat | yes | | `chat.intent` | `IntentClassifier.swift` |
| shell destructive second opinion | yes | (done before) | `shell.destructive` | `ShellTool.swift` |
| DecisionGate | yes | (done before) | `jax.gate` | `Jax/DecisionGate.swift` |
| window and app target resolution | yes | yes | `app.intent`, on the voice call | `VoiceCommandRouter`, `WindowTargets` |
| which app satisfies a spoken intent | | yes | `app.intent` (the same question) | `VoiceCommandRouter.swift` |
| screen element disambiguation | | yes | `screen.element` | `ScreenElementChoice.swift` |
| scope of a sweeping window command | | yes | **not on the engine, reason recorded**: "close everything" hides every app but Grux, which is reversible, instant and exactly what was said; a per-app question buys no safety | `WindowTargets.swift`, header |
| email triage classify step | yes | yes | `email.classify` (drafting stays on a text model) | `EmailTriageEngine.swift` |
| notification classification, interrupt or batch or silent | yes | yes | `notify.triage` | `TriageClassifier.swift` |
| focus drift | yes | yes | `focus.drift` | `AmbientCoach.swift` |
| a good moment to interrupt | | yes | `focus.interrupt` | `AmbientCoach.swift` |
| mail needs-you score | yes | yes | `mail.needsYou` | `MailNeedsYou.swift` |
| approvals risk score | yes | yes | `approvals.risk` | `ApprovalRiskJudgment.swift` |
| task priority | yes | yes | `task.priority` | `TaskJudgments.swift` |
| meeting moment detection | yes | yes | `meeting.moment` | `MeetingMomentJudgment.swift` |
| project attribution, tasks and memories | | yes | `project.attribution`: tasks, logged decisions, and (added in this gate) ambient memories | `TaskJudgments`, `DecisionLog`, `AmbientMemoryExtractor` |
| is this agent job worth starting | | yes | `agent.worthStarting` (the LIVE dispatch, the only unattended paid start) | `AgentWorthJudgment.swift` |

17 of 18 on the engine, 1 with its reason recorded in the code. Ambient
memories were the one open gap: P-R-6 had left them unattributed only because
`Ambient/*` was outside that lane. They now share `ProjectAttribution.fill`
with the decision log (one call per extraction pass, blanks only, never an
invented project). `MemoryAttributionTests` (3), red-proven three ways: tagged
items asked too, an invented or weak pick filed, memories stored before they
are filed.

**3. Before and after latency per gate, from the ledger.** The P-R-10 section
above: voice p50 441 to 392 ms and 4,460 to 2,241 input tokens; a spoken
request to Chat from two calls to one at 341 ms; every new gate's p50.

**4. `swift test` green at or above 2763.** **2951 executed, 10 skipped, 0 failures** (P-H-1 above), against a floor of 2763.

**5. Destructive-never and keyless parity.** `DestructiveNeverTests.test_certainShellCommand_isRefusedNotExecuted`
refuses `rm -rf ~`, `git reset --hard`, `drop database users` and `dd` against a
0.99 answer; `ShellSecondOpinionTests.test_aCertainProviderCannotClearACommandTheTextGuardFlagged`.
Keyless: `DecisionEventTests.test_keylessEventAnswersEveryGateAsItsDirectCallWould`,
`VoiceVocabularyTrimTests.test_keylessAnswersAreUnchangedByTheTrim`,
`WindowTargetsTests.test_keylessSpeakingAnAppByNameBringsItForward`, and one
keyless test per P-R-6 judgment (`WorkJudgmentTests`), P-R-3
(`test_aKeylessInstallSeesNothing`) and memories
(`test_keylessMemoriesComeBackUntouched`).

**6. Credit exhaustion known from the response.** The P-R-3 section above: five
keys on one monitor, one notice and one Usage card line, only after a prior
success. NOT PROVEN live: an out-of-credit episode, because no key is out.

**7. Idle CPU with the mic muted below 24%, measured the same way, with a
second profile.** The P-R-8 section above: 33.3% to **1.0%** muted
(`measure-idle-load.sh`, 12 samples 5 s apart after 90 s), and
`profile-summary.txt`: display cycle 1248 main-thread samples to 6.


## P-C-3 closed: the last two folds, 2026-09-21

**C10, Approvals into a global tray.** A badge at the foot of the rail, on
every tab, drawn only while something waits (`ApprovalsTrayButton`); it opens
the same cards Jax HQ shows, approve and skip wired to the queue exactly as
there. It observes the queue itself, so the rail's root never redraws for an
approval. `fire-open-tab approvals` opens Today with the tray open, instead of
falling through to Chat the way an unknown key does. Today's Watching card no
longer says "38 approvals waiting on you": the tray owns that, and one view
saying it twice breaks the operator's rule.

**C11, the Focus log into Today.** The rail row is gone
(`SidebarIA.awaitingTheirNewHome` is empty, so the rail is a flat 14 on first
run), the `focus` key still opens the log with Today as its host, and
Watching links to it: "Focusing on <task>" while a task is in focus, and
"N focus checks today" on a day with checks but no task, so it stays one tap
away.

Tests: `ApprovalsTrayAndFocusFoldTests` (6), `TodayModelTests` (2 new),
`RailReachabilityTests` (the tray's route, and the prop list pinned empty).
Red-proven five ways, each restored and `diff`ed identical: the tray removed
from the foot (2 failures, including "approvals lost its only route"); the
Focus log unhosted ("focus" is not "home"); Watching listing approvals again;
the Focus log back on the rail (rail 15, not 14); the approvals key opening
nothing.

**Live, 3:27 PM install, signed in, rail as the operator has it (Developer
door open):** `fire-open-tab approvals` logged `approvals tray (38 waiting)`
and the popover opened over Today with the first card's Approve, Edit and
Skip (`approvals-tray-open.png`); the Focus log opened by its key with no
Focus log row in the rail (`focus-log-folded.png`); Watching read the task in
focus and "14 improvements to review", and no approvals
(`today-watching-without-approvals.png`). All in
`docs/superpowers/evidence/2026-09-21-folds-and-today/`.


## P-C-4, C13: the Domain monitor ripped, in the order the plan wrote down, 2026-09-21

It was attempted and reverted on 2026-09-20 because it looked mechanical and
was not. Done now in the plan's order, with every count stated.

1. **The Empire dashboard's domain section** is gone, with the dashboard's
   observation of the monitor.
2. **The two stored credentials are deliberately LEFT in the Keychain.**
   `KeychainStore.Key.goDaddyApiKey` and `.goDaddyApiSecret` stay, read by
   nothing, with a comment saying why: removing an identifier strands the item
   where nothing can find or remove it, and deleting a person's credential is
   not something a rip decides on its own.
3. **The credentials contract**: `key.godaddy` removed from the vocabulary by
   contract amendment **CR-37** (it would otherwise be declared by zero
   features, which the contract treats as dead vocabulary), and from
   `SetupRequirement`, the resolver's Keychain mapping, its alternate source
   and its secret companion. `scripts/check-contract.py`: clean, self-test 16
   of 16.
4. **`DomainMonitorCapabilityTests` deleted** (9 tests), and one test that
   read `DomainMonitor.swift` replaced by
   `LaunchFlagGateTests.testNothingReadsTheRippedRegistryCredentialSources`,
   red-proven by planting a read of `godaddy-creds.json`.
5. **The registry row and its document together**: `domains` out of
   `FeatureRegistry`, `docs/feature-registry.md`, the disposition table and
   the tabless list. Also gone: `DomainMonitor.swift` (351 lines), its launch
   start, `GruxConfig.domainMonitorEnabled`, the Settings section and its
   search entry, the `fire-domain-renewal-test` trigger, and the control
   tool's note that pointed at it.
6. **Counts, reconciled**: registry rows 39 to 38; capabilities 41 to 40;
   key capabilities 12 to 11; credentials offered in Settings 9 to 8; labs
   rows 14 to 13; tabless divergent ids 13 to 12; ripped dispositions 1 to 0.
   Tests executed 2959 to **2950** (the 9 deleted, one replaced one for one),
   skipped 10 to 9 (one skip was in the deleted file), **0 failures**.

Before ripping, checked on the operator's install: `domainMonitorEnabled` was
false and its last sweep was 2026-08-30. Its state file is left where it is.
Live after the 3:57 PM install: Settings, Data and Capabilities renders its
credential list (`settings-after-domain-rip.png`).


## P-C-4 closed: brands, the first-run rail in pixels, and the Labs door, 2026-09-21

**C12, "Add a brand".** Meta Ads and Social already appeared only with a
brand (`test_brandScopedRowsAppearOnlyOnceABrandExists`); nothing let a person
add one, so the rows could never be discovered. `AddBrandRow` does, in
onboarding's Connections step and in a Settings section (Data and
Capabilities, Brands, findable by search and by `settings:brands`). It writes
`~/.grux/brands.json` through `BrandRoster.adding`, which is pure and keeps
every key the hand-editable file already carries, refuses a duplicate id
(brands and support inboxes both), a blank, and `all` (the filter's
match-everything token), and files "Harbor Bakery" as `harbor-bakery`. The
running roster is read once on purpose, so the copy says the rows appear the
next time Grux starts. Outreach has no registry row, so there is no row to
scope. `AddBrandTests` (6), red-proven four ways: the writer dropping keys it
does not know, duplicates written again, onboarding no longer naming the door,
and the `brands` deep link missing (it opened General live before the alias
existed). **NOT PROVEN live: the Brands section on screen.** The deep link
lands on Data and Capabilities, but that pane does not scroll to its anchors:
`settings:memory`, an older anchor in the same pane, does not scroll either.
That is an older defect, recorded here and not fixed in this packet.

**C14, the first-run count in pixels: 14.** No state on this Mac may be
reset, and a second live instance would share the operator's preferences (43
files write `UserDefaults.standard`), so the capture renders the app's own
`LaunchRootView` on the suite's clean state: a fresh temporary support
directory, the default config, no brands, onboarding finished in that scratch
state (`FirstRunRailCaptureTests`, which writes the PNG when
`GRUX_FIRST_RUN_CAPTURE` is set). **The first render found a defect**: every
sidebar group started expanded, so the Labs door opened itself and a first
run showed 21 lines. A fresh install now starts with both doors collapsed
("Developer (collapsed, counted); Labs (collapsed, counted)", design section
3), and an install with saved sidebar choices keeps them. The second render
reads Home, Chat, Mail, Calendar, Notes, Documents, Contacts, Tasks,
Meetings, Schedules, Integrations, Studio, **LABS 8 BETA**, Settings: 14
(`first-run-rail.png`, cropped to the rail).

**B16, finished: Labs is badged once at the door.** Moved from Phase B to
C2 because removing the pills before the door existed broke onboarding's
promise that labs features are labelled; the door exists, so both halves land
together. Rows behind the Labs door no longer carry a pill and the door header
does; a labs row that no door covers (Agents behind Developer, a brand's Meta
Ads and Social) keeps its own, because the promise covers it too. On a clean
install that is zero per-row pills, which is what G-F checks.
`BetaBadgeTests.testTheLabsDoorIsBadgedOnceAndItsRowsAreNot`; red-proven
three ways (doors open on a fresh install, the door's badge removed, pills back
behind the door).

**Suite: 2958 executed, 9 skipped, 0 failures.** `check-contract.py` clean.

Also seen while rendering: the suite reads the operator's real calendar and
the Keychain's "a model key exists" answer (the render showed their events,
and onboarding took the reinstall path). Reads, not writes, and outside
P-H-1's `~/.grux` scope; noted for the hygiene list.


## G-C: the Phase C gate, 2026-09-21

1. **Every task checked, committed and pushed**: C1 to C14 (P-C-1 to P-C-4
   rows above).
2. **`swift build` 0, `swift test` 0: 2961 executed, 9 skipped, 0 failures**
   (floor 2653).
3. **`RegistryReachabilityTests` and `SidebarRowCountTests` red-proven**, each
   restored and `diff`ed identical: Speakers put back on the rail ("13 is not
   12, rail rows" and "8 is not 9, folds"); Settings dropped from the rail
   ("15 is not 16" with a brand, and Labs where Settings must be last).
4. **A sweep of every door**, 3:39 to 4:50 PM installs, signed in, the
   operator's rail (Developer door unlocked and open), in
   `docs/superpowers/evidence/2026-09-21-gate-c/`:
   - `rail-surfaces.png`: the twelve rail rows and Settings, 13 captures.
   - `door-surfaces.png`: the Developer door's five (Commands, Terminal
     Focus, Agents, Local Models, Compare) and the Labs door's seven (Reactor,
     Jax HQ, Jax Command, Cognition Map, Feature Review, Self-Upgrade,
     Roadmap), each opened by its key; the operator's rail shows the Developer
     door open in every capture.
   - `labs-door-open.png`: the Labs door open, from the first clean-state
     render (the one that found the door opening itself; see C14).
   - `folds.png`: all nine folds inside their parents: Speakers in Meetings,
     Workflows in Schedules, Projects in Tasks, Skills in Chat, Media Studio
     and Research in Studio, the Focus log by its key under Today, Folders in
     Settings, Compose in Mail's header, the approvals tray, and Outbound
     Webhooks in Integrations. Webhooks sits below the fold of Integrations, so
     C5's rule (a child opens its parent at the child) got the key it lacked:
     `fire-open-tab integrations:webhooks` scrolls there
     (`test_theWebhooksKeyOpensIntegrationsAtWebhooks`, red-proven).
5. **All 35 locked keys resolve, asserted on what RENDERED, not the ack.**
   The detail pane now writes `~/.grux/rendered-tab.txt` from a task keyed on
   the selection, after the pane updates (`RenderedTabHookTests`, red-proven by
   removing the hook). `tools/grux-tab-keys-check.sh` fires each key, waits
   for that file to name it, and reads **"35 keys: 35 rendered as asked, 0 did
   not"**, twice (4:39 PM install). A bogus key fails it ("nosuchtab, rendered:
   nothing"), so the check can fail.
6. **The first-run rail: 14**, `first-run-rail.png` (C14 above).

Found on the way and fixed: the approvals tray opened by key stayed open over
whatever the next key opened (a programmatic tab change is not a click
outside the popover); any other key now closes it (red-proven).

Found and NOT fixed, for the hygiene list: a test render of `IntegrationsView`
showed the operator's real TypeSafe key, masked, in its field. Keychain reads
never prompt (`KeychainStore.neverPrompt`), and they are not isolated under
test the way `Persistence` is; the render was deleted, not committed.


## D5 and G-D: Home is Today, and Phase D's gate, 2026-09-21

**D5.** The rail row, the registry row and the sidebar table read **Today**;
the key stays `home`, because scripts, the CLI and every saved sidebar state
use it. The registry document, the rail test that names the twelve surfaces,
and the README's permission table changed with it (`PermissionTableTests`
caught the README still saying "the agenda on Home"). Onboarding had no
mention to change. `TodayIsNamedTodayTests` (2): every label for the key reads
Today and no shipped string says "Home" for it; red-proven by putting the
registry label back.

**G-D.**

1. D1 to D5 committed and pushed (P-D-1 row).
2. `swift build` 0; **`swift test`: 2963 executed, 9 skipped, 0 failures**
   after the README fix (floor 2653).
3. Every Phase D test red-proven once: D1 to D4 when they landed, D5 here.
4. **Today, swept on the running app**, 5:10 PM install, pid started at the
   installed binary's modification time to the second (both `Mon Sep 21
   17:10:35 2026`), signed in: the rail reads Today, "Good evening" with the
   operator's name, Next, Mail that needs you, Watching
   (`docs/superpowers/evidence/2026-09-21-gate-d/today-live-5-10pm.png`). The
   say-it line sits below the fold there, and the operator closed the window
   twice while it was being driven, so the line is shown from the app's own
   `LaunchRootView` rendered on the suite's clean state: "Just say it. Grux is
   listening, no wake word needed." under Start my day (`say-it-line.png`).
5. **The briefing's decision line comes from the ledger.** As text, from the
   saved briefing (`~/.grux/jax/briefings/latest.json`, generated 5:00 PM):
   `265 decisions today, 407 ms average, $0.02 | all on Jev`. Beside it,
   `~/Library/Application Support/Grux/decisions.jsonl` holds **265** rows
   dated today in local time (of 1,064), so the number is the ledger's.


## G-A: the Phase A gate, 2026-09-21

1. **Suite: 2965 executed, 9 skipped, 0 failures** (floor 2579).
2. **Every Phase A test red-proven once**, when it landed (sections "Phase
   A, the tells" and "Phase A gates on the engine" above, and each Phase R
   packet that absorbed an A row).
3. **`mic-status.json` flips with the Listening control**, 5:20 PM, through
   the app's own triggers: before, `micMuted false, ambientCapturing true`;
   after `fire-mic-mute`, `micMuted true, ambientCapturing false`; after
   `fire-mic-unmute`, `micMuted false, ambientCapturing true`, and the log
   shows ambient STARTED and `hearing 1.9s of audio` two seconds later (with
   the AirPods connected, listening moved to the MacBook Pro Microphone as
   P-R-9 designed).
4. **A Chat sweep with the listening chip and the live rail**, 5:31 PM
   install, signed in: the chat header's listening chip reads ARMED (the
   word the shared tell uses for always-on listening since P-A8), and after
   one line of room talk was injected, the live rail above the composer reads
   "the weather looks really nice outside this afternoon | not for Grux"
   (`docs/superpowers/evidence/2026-09-21-gate-a/`).

**Found in that capture and fixed: the composer's model chip named the wrong
model.** It showed "Llama3.2" while chat routed to OpenRouter's DeepSeek,
because it read `offlineLLMModel` for any route that was not Anthropic; and
its menu set stored ids without switching the route, so picking a Claude
model under a custom route changed nothing, and picking an endpoint wrote the
endpoint's NAME as a model id. The chip now reads `ModelRegistry.modelId()`,
the same answer `ChatService` sends with, and each menu choice switches the
route. Live after the fix: "Deepseek V4 Flash 0731"
(`live-rail-and-model-chip.png`). `ComposerModelChipTests` (2), red-proven
twice. The old "Offline mode is on" replies in that thread are from the
evening of 2026-09-20, not today.

## P-F-1: first run, the logic built and the screens offered, 2026-09-21

**What waits, and why it is not work left undone.** The decision record
(`questionnaires/_decisions/grux-rethink-2026-09.md`) names three surfaces to
be rethought and shown as 1:1 visuals before they are built: Tuning, Labs and
the first-run prompt. So the first-run SCREENS join the batched decision in
`docs/superpowers/visuals/README.md` (first-run A, the question alone; B, the
question with starting points; plus the setup that follows, one at a time and
as a list). Everything under those screens is built, tested and red-proven.

**F2, the answer selects features (`Onboarding/IntentToFeatures.swift`).**
Keyless first: the floor (Chat, Mail, Calendar, Notes, Tasks) plus Today,
Approvals and Settings for every answer, plus every row whose words the answer
uses, whole-word so "ui" never fires inside "build". "I write code" and eight
variants select Commands, Terminal Focus and Agents, and the Developer door is
unlocked by the DISPOSITION of any picked row, not a second list, so "keep
everything offline" opens it for Local Models too. A key adds rows in one Jev
call and never removes one. `IntentToFeaturesTests` 15.

**Calibrated, because the first wording failed.** 24 answers against
jev-latest (grux-ecosystem key), 30 rows each, $0.00100 of input, p50 358 ms.
"Their answer asks for X, or plainly needs it" said yes to Workflows, Skills,
Agents and Commands for nearly everything: precision 0.26 at 0.70. Five
rewordings later, "The answer mentions something that X is for. X: purpose."
What the app returns (words plus Jev at 0.80): precision 0.95, recall 0.95 on
the 16 in-sample answers; 0.80 and 0.89 on the 8 held out, against 0.88 and
0.78 for the words alone. Threshold chosen in-sample only.
`2026-09-21-p-f-1/calibration-2026-09-21.txt` (and `-first-wording.txt`),
reproducible with `calibrate-intent.py`, which reads the wording and the word
tables from the Swift source.

**F3, setup in an order with real logic (`Onboarding/SetupOrder.swift`).**
Done items are shown done; then what the most selected features need; then
cheapest (toggle, paste, somebody else's website, macOS permission); optional
offered once at the end, skippable whole; and no step before the permission it
needs (the first look after Screen Recording). The model gate is never asked
twice. Listening is planned beside the features and stays in the plan until it
has STARTED, because a granted microphone is not consent. One at a time: no
screen asks for more than one decision and "N left" is always true.
End to end, "Run my inbox and transcribe my meetings" on a clean Mac:
Microphone (serves Listening and Meetings), recording consent, speech model,
mail server, Calendar, System audio; 7 left on the first screen; 15 extras.
`SetupOrderTests` 14, including the rule swap kept as a test.

**Found and fixed on the way.**
- **A fresh install read ARMED with no microphone open.** Listening is on by
  default by decision, and launch never opens a consent dialog over the first
  screen, so the preference said always on while nothing listened. The tell
  now resolves from `GruxConfig.listeningModeInEffect` (each mode counts only
  once its own consent is given) on all 7 surfaces, and a source scan fails
  any surface that passes the raw preference.
- **The Developer door had no switch anywhere.** `developerSurfacesUnlocked`
  was read by the rail and written by nothing, so a new install could never
  show Commands, Agents, Terminal Focus, Local Models or Compare. Settings,
  General, "Sidebar doors" is its permanent home, its copy names the rows from
  the registry and explains the off state, and search and the `developer` and
  `doors` deep links reach it.
- **F4:** "How Grux works" now names the command palette with its shortcut
  (Command-Shift-P), the Developer door and the Labs door. Tuning is named
  when it exists (P-E-2, Task E-last), not before.
- **F5:** `~/.grux/fire-first-run-reset` puts the flow back and clears the
  feature selection; keys, consent and permissions stay.

**Red-proven:** 19 plants in five runs (four batches plus the end-to-end
test), every target red, every file restored and `cmp`-identical; then two
more for the calibration pin. `FirstRunHonestyTests` 9.

**Recorded, not changed:** the contract's microphone `why` still ends
"Continuous listening is a separate switch that ships off", which the
listening-on-by-default decision made untrue; contract text changes by CR.

## P-G-1: version 3.0 everywhere, the CHANGELOG, and the site counts, 2026-09-21

**The version sweep, counted.** `grep -rn "1\.2\.1"` across the repo
(excluding `.build`, `node_modules` and these plan documents, which make it
20) found **17 files**. **4 of them carry the version, in 6 places**, and all
6 changed: `Info.plist`
(`CFBundleShortVersionString` 3.0.0, `CFBundleVersion` 7 to 8, changed with
`plutil` so the diff is two lines), `npm/package.json` (3.0.0), `README.md`
(the status line and the download button), and `CHANGELOG.md` (the
`[Unreleased]` compare link now starts at v3.0.0, plus a `[3.0.0]` link). **The
other 13 are reconciled by name as history or a section number, and stay**:
`docs/contract.md` section "1.2.1" and the four files that cite it
(`PermissionsSection.swift`, `OnboardingSteps.swift`, `SetupContract.swift`,
`PermissionWhyContractTests.swift`), and past-tense mentions of the 1.2.1
release in `ShippedDocsTellTheTruthTests`, `PrivateServiceFetchTests`,
`MotionGateTests`, `NoSurpriseFoldersTests`, `KeychainStore.swift`,
`extract-oss.py`, `cli-grammar.md` and `feature-registry.md`; the CHANGELOG's
own 1.2.1 heading and link are history too. Installed: `defaults read
/Applications/Grux.app/Contents/Info CFBundleShortVersionString` reads
**3.0.0**, build **8**, on the 6:27 PM install (pid start equal to the binary
mtime).

**`ReleaseVersionAgreesTests` (2)**: `Info.plist` and `npm/package.json` carry
the same version, the CHANGELOG has its entry, and the README's status line and
download button name it. Red-proven twice (npm drifted to 3.0.1; the download
button back to 1.2.1), restored and `cmp`-identical.

**The README** said 39 features, 25 core and 14 labs "badged BETA in the
sidebar", and listed the ripped Domain monitor. It now says 38, 25 and 13, and
describes the one-badge-at-the-door rule that `BetaBadgeTests` asserts both
halves of. Test line: 3005.

**The CHANGELOG's 3.0.0 entry** is marked "staged, not released" and says
plainly that Tuning, Labs and the first-run screens land before release. Its
latency table has one row per gate that moved, each with where its number comes
from: the ledger (`scripts/decision-latency-table.py --before-end
2026-09-21T14:33:00Z --after-start 2026-09-21T14:50:00Z`, 1,065 ledger rows,
the latest at 9:31 PM UTC), or the P-R-5, P-R-6 and P-F-1 calibration runs
where a gate has no live rows. It names the slowdown: every gate that was a
keyword or a rule now takes about 350 to 450 ms with a key, where it took under
5 ms. The copy linter over `CHANGELOG.md` and `README.md` (dashes, dollar amounts, secrets): clean.

**Site counts (G3), dry-run now, re-sync after publish.** The live site
(its own repository) fetches every number from the PUBLIC repo with
`tools/fetch-facts.py`, which asserts every parse and dies on a miss, so it
cannot re-sync until 3.0 is published there, and deploying it is a production
step that takes the word. Run today against the local 3.0 files, with only the
unpublished release stubbed, the site's own parse code read: **features 38,
core 25, labs 13, tools 116, tests 3003** (before the two version tests
landed), and no `domains` row. So the parse points survive the 3.0 README.
Staged for after the word: `fetch-facts.py`, `build-geo.py`, `check.sh`, a
preview deploy, then production.

**Suite: 3005 executed, 9 skipped, 0 failures.**

## P-G-2: the guarantees, the notarized build, and a candidate staged, 2026-09-21

**`scripts/oss-guarantee.sh`: PASS**, quoted: "PASS: 1129 file(s) would
publish, every byte read, no banned string, no commit history, and the Swift
identity guard agrees." Its self-test first: "PASS: every check in the
guarantee is proven able to fail." It failed three times before it passed, and
each failure was real:
- five text leaks: the calibration script's run line named the private key's
  Keychain item, one evidence line named a private linter, and three lines named
  home paths (two from earlier sessions). Reworded.
- **36 unreviewed images, and the image review is the one that mattered.** They
  are 3.0's verification captures and design renders. One capture checked by
  eye (the gate-d Today view) shows the operator's name, tasks, mail senders
  and a sign-up code. `Grux-Mac/docs/superpowers/evidence` and `.../visuals`
  are now excluded from the public tree as folders, with the reason beside
  them in `scripts/oss-exclude.txt`, so a capture added tomorrow cannot ship by
  default. They stay in this private repository.
- one identity-guard hit in this file's own P-G-1 section. Reworded.

**`scripts/check-contract.py`: clean**, quoted: "clean, no drift".

**The MIT tree carries no TypeSafe key.** Scanned the extracted tree (1129
files) with the real key read from the Keychain into memory, never printed.
The scan was proven first by planting the key into a scratch copy of a real
source file: found. Then: the key value, 0 files; its first 24 characters, 0;
the Keychain item's name, 0; the console key name, 0. The endpoint host appears
in 2 Swift files by design (the bring-your-own-key provider and a comment in the
credit signatures): the MIT build lets a person use their own key from their
own Keychain, which is what the Definition of Done asks for.

**The notarized build.** `GRUX_RELEASE=1 GRUX_NOTARIZE=1 ./build.sh` with the
App Store Connect API key, 6:31 to 6:52 PM: notary status **Accepted**, "The
staple and validate action worked!". On the staged app: `spctl --assess`
"accepted, source=Notarized Developer ID"; `codesign --verify --strict --deep`
"valid on disk, satisfies its Designated Requirement"; version 3.0.0, bundle
`com.gruxai.grux`. Unzipped again from the staged zip: accepted and stapled.
`ShippedBundleHygieneTests` 5 of 5 (none skipped). On the NOTARIZED binary
itself: the certificate's organization name occurs 2 times, 0 before the
signature boundary; the TypeSafe key value is in 0 of the bundle's 13 files,
with the same planted control seen first.

**Staged, not published** (`~/Downloads/Grux-3.0.0-candidate/`, outside the
repository): `Grux-3.0.0-macOS-arm64.zip` and `Grux-macOS-arm64.zip`, the two
names 1.2.1 shipped under (23,931,135 bytes, sha256 `db1617a5...5fafb`),
the npm package tarball from `npm pack` (npm tests 11 of 11), the draft
release notes cut from the CHANGELOG entry, and `SHA256SUMS.txt`. A local tag
marks the commit. Nothing was pushed as a tag, no GitHub release exists, and
nothing went to npm.

**This is a CANDIDATE.** Tuning, Labs and the first-run screens are not in it;
they land after the batched decision, and the release is rebuilt, re-notarized
and re-staged then. The notarized stranger walk (Task G5's last step) is the
G-F run on that final build.

## G-G: the nine Definition of Done items, each with its evidence, 2026-09-21

From `questionnaires/_decisions/grux-rethink-2026-09.md` (kept outside this
repository), in its order. PROVEN names an artifact; WAITING names who and what.

1. **Clean VM stranger run** (at most 14 rows, no BETA pill, listening named
   with its off state, "open my calendar" spoken under 1 second). **WAITING ON
   OPERATOR**: runs after the first-run screens are built from the batched
   decision. Ready to walk: `evidence/2026-09-21-p-f-1/g-f-clean-vm-runbook.md`,
   including the per-row pill conflict to settle first. Already PROVEN in parts:
   the first-run rail is 14 in pixels (`folds-and-today/first-run-rail.png`,
   "P-C-4 closed"); a fresh install no longer reads ARMED before consent
   ("P-F-1").
2. **Jargon test red-proven.** PROVEN: `JargonInTheFaceTests`, `103741d`,
   planted one of each kind ("Phase B: P-B-1 and P-B-4 closed").
3. **Every registry row has a recorded disposition and a reachable door.**
   PROVEN: `RegistryReachabilityTests` red-proven ("P-C-1", "G-C"), 35 of 35 tab
   keys asserted on what rendered ("G-C"). P-F-1 found the one door with no
   switch (Developer) and gave it one in Settings.
4. **Jev never acts alone on anything destructive.** PROVEN:
   `DestructiveNeverTests` red-proven ("Phase A"), and
   `test_certainShellCommand_isRefusedNotExecuted` refuses `rm -rf ~`, `git reset
   --hard`, `drop database users` and `dd` whatever the engine says ("G-R", item 5).
5. **The wake-word downgrade works from the one Listening control, both ways,
   by `mic-status.json`.** PROVEN: "G-A", item 3, through the app's own triggers.
6. **The MIT build carries no TypeSafe key.** PROVEN: "P-G-2".
7. **Build, tests, contract check, OSS guarantee.** PROVEN: "P-G-2".
8. **Chat matches the accepted finished face**, swept, pid start equal to the
   installed binary mtime. PROVEN: "G-B" (item by item) and "G-A" item 4.
9. **Release notes carry the measured before and after latency of every gate
   moved onto the engine.** PROVEN: `CHANGELOG.md` 3.0.0, "P-G-1".

**Updated 2026-09-22. The release IS final now**: Tuning, Labs and the
first-run screens are in it, and the candidate was rebuilt, re-notarized and
re-staged with fresh checksums ("P-G-2, the final build"). Items 6 and 7 are
re-PROVEN on that build rather than on the older candidate. Item 9 still holds:
the CHANGELOG was rewritten to what actually ships, latency table included.

**Eight of the nine are PROVEN. One is the operator's**: item 1, the clean VM
stranger run, which walks the final build and settles the per-row pill conflict
the runbook names. Publishing waits for the word.

## P-O-1: Optimize Grux, the one front door for changing Grux, 2026-09-21

**The ask** (the operator, 2026-09-21 evening): nothing a person does not need
stays in front of them; customizing Grux goes through their own coding agent,
by copy-prompt handoff, end to end, on a generalized work order whose only
limit is the agent's. Modelled on a ten-station line with three human reviews
(eleven since preflight joined on 2026-09-22).

**What landed.**
- `Optimize/WorkOrder.swift`: eleven stations and three reviews, fourteen
  stops in the line, in the diagram's order (preflight, requirements,
  analysis, review-1, design, architecture, governance, review-2, build,
  validate, review-3, install, verify, monitor; preflight joined the front on
  2026-09-22, see "Optimize Grux: the preflight station"), a tolerant
  progress parser, and ONE work-order template for every request. The agent,
  not Grux, decides at analysis whether it is a setting or code, and the
  template tells it to check settings first ("make the accent red" is
  `theme.json` accentHue, no code).
- `Optimize/WorkOrderStore.swift`: one folder per order under
  `~/.grux/work-orders/<id>/` (`order.json`, `work-order.md`, `progress.log`).
  The agent reports with one `echo` per station; Grux reads it back.
- `Optimize/OptimizeGruxView.swift`: an "Optimize Grux" button under the GRUX
  OS wordmark (not a rail row; the first-run rail stays 14), a panel with the
  request field, Copy work order, and each order's position on the line; an
  amber dot on the button while an order waits at a review. Remove asks first.
- Reachable from the command palette and `fire-optimize`; named at first run
  in How Grux works; `build.sh` records `~/.grux/source.json` on local installs
  only, so a work order tells the agent to work in the checkout the running app
  came from, or, for the downloaded release, to clone the matching tag from the
  repository gruxai.com links.

**Two defects the existing guards caught in it, fixed:** Remove deleted with
no confirmation (`DestructiveActionsGuardTests`); the work order named the bundle
id (`NoTerminalInstructionsInUITests`) and then the repository URL, which put
the author's handle into the installed binary (`ShippedBundleHygieneTests`).
The downloaded case now points at gruxai.com, pinned by a test.

**Found on the way, fixed: screen control handed out off-screen clicks.**
`isOnADisplay` flipped the screens into a span from y = -height to +height, so
a scrolled Finder list's rows at y = -2,563 were reported click-ready. Its test
only tried a row 7,000 points up. Now each screen is flipped around the main
display's top edge and judged on its own; three pure tests (just above the
display, a display stacked above, the gap beside a shorter display), each red
on the old math, and the live Finder test passes with the scrolled window open.

**Live, 8:17 PM install** (pid start equal to binary mtime): `fire-optimize`
with "change grux color accent to red" wrote `wo-45xju8`; its work order names
the local build, this checkout and commit, both settings files and the progress
path. Renders from the app's own views in the test host:
`evidence/2026-09-21-optimize/optimize-sidebar-crop.png` (the button) and
`optimize-panel.png` (three orders: waiting for an agent, paused amber at
review-1 with the agent's question, done).

**Tests:** `OptimizeGruxTests` 14 and `OptimizeGruxCaptureTests` 1, red-proven
with 7 plants; `ScreenControlOffScreenElementTests` 4, red-proven with 2.
**Suite: 3023 executed, 9 skipped, 0 failures.**

## P-E-3: the Labs shelf, and BETA said once, 2026-09-22

**Built after the pick was recorded** (P-E-1 at `5af1492`, this after it).
- **The shelf, accepted shape A** (`labs-a.png`): `Labs/LabsShelfView.swift`,
  a `labs` tab the Labs door's header opens (its chevron still lists the rows).
  Eight cards read from the registry (every row behind the door, then Roadmap),
  one line each; the phone card opens the pairing window. The render's intro
  sentence "Nothing in Labs acts outside the approvals you already set" was
  dropped: Self-Upgrade at TIER 2 lands code without asking each time, so it
  was not true. Render: `evidence/2026-09-22-labs/labs-shelf.png`.
- **BETA, as decided**: no sidebar row draws a pill. The Labs door carries one
  badge; each labs feature outside that door (computed from the registry:
  Agents, Terminal Focus, Media Studio, Workflows, Compose, Meta Ads, Social)
  says BETA once beside its own title via `LabsHeaderBadge`. Agents had no
  title of its own and gained one.
- Tab count 35 to 36 (`labs`), with no registry row and therefore no gate, the
  same as Roadmap; `TabAdoptionTests` and `CLAUDE.md` updated with the reason.

**Tests:** `LabsShelfTests` 4 and `BetaBadgeTests` rewritten for the new rule
(no pill on any row, the door's one badge, every outside feature labelled, the
onboarding promise kept), red-proven with 5 plants. Suite 3030 executed, 9
skipped, 0 failures. Installed 9:23 PM, pid start equal to binary mtime.

## P-E-2: Tuning, the behaviour cards, 2026-09-22

**Built after the pick was recorded** (P-E-1 at `5af1492`, this after it).
- **Shape C, as accepted** (`tuning-c.png`): `Tuning/TuningView.swift`, two
  columns of cards named for what Grux does (Acts on what I say, Talks back,
  Interrupts me, Works on its own, Spends, Remembers, Asks before), each line
  read from live values, the open card tinted and outlined in the accent, each
  dial's value right-aligned in the accent. The eighth place is "Tell Grux what
  you want", which opens Optimize Grux. Renders:
  `evidence/2026-09-22-tuning/tuning-acts.png`, `tuning-alone.png`,
  `tuning-spends.png` (test-host renders of the app's own view).
- **All eighteen controls the operator ticked**, each bound to the one config
  value it always had and saved on change: execute threshold, daily decision
  budget, Decisions key status, listening mode, decision banners, speak aloud,
  voice speed, focus nudge cooldown, stuck nudge, energy, self-upgrade ceiling,
  intelligence tier (with its monthly cost per tier), active hours, snooze, the
  Usage card, the ledger's last five rows, live latency, memory on or off,
  recap hours.
- **Where it lives, as decided**: a `tuning` tab with no rail row (first-run
  rail still 14), opened from a right click on the orb, a "Tune how Grux works"
  link on Today, the command palette, two menu bar
  items (Tuning, and Tell Grux what you want), and a Tuning section at the top
  of Settings General (`tuning-settings-link.png`), with a search entry and a
  `tuning` alias.
- **The moved controls left Settings.** Active hours, snooze, speak aloud, voice
  speed, the tier cards, the memory switch, the listening mode picker and the
  banner switch are gone from Settings; each old place shows one line saying
  where it went and an Open Tuning button. Settings' `save()` wrote every
  `@State` mirror it held, so a mirror loaded before a Tuning change would have
  put the old value back; the eight mirrors are removed from the declarations,
  `loadFromState` and `save`. Six lines of copy that sent people to Settings
  for listening, the banners or the self-upgrade tier now say Tuning.

**Two new dials, enforced where the decision is made:**
- `dailyDecisionBudget` (0 is no cap): past it, `DecisionEngine.keyLookup()`
  reads the key as absent until midnight, so the single call and the batched
  event both answer on device. Counted as recorded in `DecisionLedger`, NOT off
  `recent`: that list keeps the last 2,000 rows of every provider, so a cap
  above what it held would never have tripped. `hasSavedKey` is separate from
  `hasRemoteKey`, so a capped install is told "until midnight", not "Add a key".
- `selfUpgradeMaxTier`: `FoundryEngine.cappedTier` at the auto-land decision,
  which only ever lowers the earned tier and fails closed at propose. New
  installs start at 0 (proposes only); a config written before the dial decodes
  to 2, so an install keeps what its lanes already earned.

**One control was cut rather than moved.** `bargeInEnabled` had a Settings
switch and no reader anywhere since the first commit; `SpeechEngine` documents
that it deliberately does not listen while it talks. Moving it into Tuning
would have shipped a switch that does nothing, so the field is removed and the
Talks back card says the true way to interrupt (the microphone in Chat, or
mute). A guard now fails any Tuning dial that nothing outside Tuning and
Settings reads.

**Also fixed on the way:** the voice speed read `%.2g`, so 1.25 showed as
"1.2"; Tuning's slider steps 0.05, as Settings' did.

**Tests:** `TuningTests` 18 (summaries, rate, dashes, the cap and its day
boundary, the trim, no call past the cap, the shipped engine reads config and
never under test, the ceiling and its call site, the defaults, every entry
point, the Settings link and search, the dial scan, no Settings writer of a
Tuning value, no dead dial, a pointer in every moved section, the interrupt
line), plus the Tuning renders in `OptimizeGruxCaptureTests`. Red-proven with
10 plants, each restored byte-for-byte (shasum):
budget guard, count off `recent`, ceiling ignored, ceiling not applied, a
dead dial, a stale Settings save, a missing pointer, `%.2g`, the Today door,
old installs losing autonomy (log: all ten RED). Two copy tests
(`ComposerPlaceholderTests`, `VoiceDecisionBannerTests`) went red against the
old "in Settings" lines and now assert "tuning"; the banner test also asserts
the switch and its explanation are both in Tuning, red-proven by a plant.

**Verified:** suite 3049 executed, 9 skipped, 0 failures. `./build.sh` on
`main`, installed 10:06 PM, pid start equal to the binary mtime (22:06:00).
On the running app, `fire-open-tab tuning` wrote `rendered-tab.txt` = `tuning`
at 10:08 PM (written only after the pane updates), then restored to `home`.
NOT PROVEN on live pixels: the launch window was not on this screen (listed
by the window server at 1040x732, off screen; `winid.swift` found none), so
the pixels are the test-host renders above. The Today render is kept out of
the repo because the test host read the real calendar; that is the open
"test isolation for Keychain and calendar" small call.

## G-E: the Phase E gate, 2026-09-22

**Visuals accepted before code, proven from git.** The operator's three picks
were recorded in `5af1492` (8:39 PM, the ledger only, one file), and
`git merge-base --is-ancestor 5af1492` holds for both view commits. The first
commit to add each view file: `Labs/LabsShelfView.swift` in `179ac6b`
(9:23 PM), `Tuning/TuningView.swift` in `f1e806e` (10:09 PM).

**The sweep, on the running app** (installed 10:06 PM, pid start equal to the
binary mtime): `fire-open-tab labs` and `fire-open-tab tuning` each wrote the
same key to `rendered-tab.txt` (10:14 PM), which is written only after the pane
updates; a made-up key rendered `chat` as the control, so the marker is not an
echo of the request. Restored to `home`, where the operator had it. Live
pixels NOT PROVEN: the launch window was off this screen, so the pixels are the
app's own views rendered in the test host, beside the accepted renders:
`visuals/labs-a.png` against `evidence/2026-09-22-labs/labs-shelf.png`, and
`visuals/tuning-c.png` against `evidence/2026-09-22-tuning/tuning-acts.png`.

**What the accepted Tuning render shows that the build does not, on purpose:**
a "Sorts my mail" card and a "Still talking to me for" slider. Neither is among
the eighteen controls the operator ticked, so neither was built.

**Held by the suite** (3049 executed, 9 skipped, 0 failures): `TuningTests`
(no rail row, every door, the moved controls, 10 plants red), `LabsShelfTests`
and `BetaBadgeTests` (5 plants red), `SidebarRowCountTests` (first-run rail
14, unchanged by Tuning).

## P-F-1: the first-run screens, the question path, 2026-09-22

**Built after the pick was recorded** (P-E-1 at `5af1492`; these after it).

**Shape A, and more than one step, as the operator asked.** A new install opens
on the question alone (`FirstPromptStep`, `first-run-a.png`): one field, a
microphone, the listening line, and "I would rather pick from a list". Then a
flow built from that answer: "Here's your Grux" (what it picked, shown before
anything is asked, add or remove any of it), the name, the model, How Grux
works, setup, Chat.

**The levels are untouched, behind the link.** Rather than a fourth level (which
would have changed every level test and said something false: the question is a
different door, not a bigger flow), the state carries a PATH. `question` is the
new front door; `list` is exactly the three levels, and any onboarding.json
written before today decodes to `list`, so an in-flight install keeps its place.

**A consent defect found and fixed on the way.** `firstFrameWasReviewed` asked
whether the person's LEVEL includes the first look. A question-path install
carries a default level, so a finished run would have recorded a captured frame
as reviewed by somebody who was never shown one, which is the exact lie that
screen exists to prevent (and the same shape as the `.done` guess P-F-1 already
fixed once). On the question path the frame counts as reviewed only when the
screen itself says so: `skippedFirstLook` starts TRUE and only
`recordFirstLookReviewed` clears it.

**The model gate now offers the three chosen paths.** Anthropic key, local
model, and an OpenRouter key. OpenRouter's model list is PUBLIC, so the
reachability probe every other endpoint uses cannot tell a good key from a bad
one; the key is judged by OpenRouter's own key endpoint. Measured 2026-09-21:
a bogus key returns 401, the real one 200, and both calls are free. The path
then adds OpenRouter as the endpoint chat routes through, starts it on
`deepseek/deepseek-v4-flash-0731` (present in OpenRouter's own model list that
day, tool use, $0.04 per million input tokens and $0.64 out), and reads the
route back before leaving the gate, exactly as the local path does.

**Setup, one thing at a time, on for everyone.** `SetupStep` walks
`SetupOrder`'s plan for the chosen features: what already works is shown done,
then one item per screen with "N left" always true, its reason above its one
control, and Skip beside it. The whole list is one switch away. Listening is
planned beside the features and runs through the existing consent door
(`ListeningController.apply`), so declining is an answer and leaves it off.
"Keep it off" does NOT close the microphone item when another picked feature
(Meetings) also needs the microphone; that item keeps its own Allow.

**The Decisions key, as decided**: named once in How Grux works with its
Integrations home, and offered in setup's optional extras (a `decisionsKey`
screen in `SetupOrder`, counted in the offer and in "N left", defaulted off so
every existing caller is unchanged), skipped with the rest.

**Chat with a first exchange done** (decision 13): on finishing the question
path, Grux opens Chat and sends the person's own answer as the first turn, only
when a model is ready and never from a test run.

**Also, one of the small calls:** the How Grux works listening line said "Two
voice features ship switched off", which 3.0 made untrue. It now describes the
one Listening control, keeps the wake phrase and Ambient mode named, says audio
never leaves the Mac, and points at Tuning.

**Tests:** `FirstRunQuestionPathTests` 21 (the order, the levels untouched, a
new install's state, an older file staying on the levels, the consent rule both
ways, the first exchange, no macOS prompt before its explanation on any screen
before setup, the microphone's own explanation, setup asking only from a button
on the item's own screen, one at a time for everyone, the Decisions key in the
extras with "N left" true at every step, the three model paths drawn, the
OpenRouter verdicts, "Here's your Grux" in plain words, the shared microphone,
and the rewritten listening line). Red-proven with 17 plants, each restored
byte-for-byte (shasum). One plant was NOT caught on the first pass and the test
was the thing at fault: deleting the OpenRouter path from the rendered body
left it green, because the assertion read the whole file rather than `var
body`. Fixed to read the body, then red.

**Renders** (the app's own views in the test host):
`evidence/2026-09-22-first-run/first-run-question.png` beside the accepted
`visuals/first-run-a.png`, `first-run-your-grux.png`, `first-run-setup.png`.

**Verified:** `./build.sh` on `main`, installed 10:48 PM, pid start 22:48:15
against binary mtime 22:48:14. On the running app the first-run flow did NOT
appear, which is the migration this change had to get right: the operator's
`onboarding.json` carries no `path` key, so it decodes to `list` and stays
`done`. NOT PROVEN on live pixels for the new screens: showing them means
`fire-first-run-reset` on the operator's install, which the handback forbids;
the clean-VM run (G-F) is where a first run is walked for real.

## Optimize Grux: the preflight station, 2026-09-22

**Why.** A person describes what they want in a sentence, and a sentence leaves
out the one or two things that change what gets built. The operator's words:
the call to action should hand off to their agent "preflighting them w a basic
dumbed down version that can't lose".

**What it is.** An eleventh station, first on the line, before anything is
analysed or built. The rules are in the work order itself, so they travel to
whatever agent the person uses:

- AT MOST THREE questions, and only ones whose answer changes what gets built
  (how far it goes, where it applies, what it replaces).
- Every question carries a recommended answer, marked, so "go with your
  recommendations" is a complete reply and saying nothing is still an answer.
- Never about implementation: which file, which pattern, how to test, are the
  agent's to decide.
- A request that needs nothing asked appends `preflight | none needed` and
  carries straight on, so the trivial case stays frictionless.

**Held by tests:** `OptimizeGruxTests` pins the eleven-station line with
preflight first, and the four rules above by their words. Red-proven with four
plants (no cap, no recommendation, preflight off the line, free rein to ask
about implementation), each restored byte-for-byte.

**Verified on the running app.** Built 10:38:17, pid started 10:38:18. Fired
`~/.grux/fire-optimize` with "add a pomodoro timer to Today": the order Grux
wrote opens `0. **preflight**` with the AT MOST THREE rule, ahead of
`1. **requirements**`. The first attempt was the honest kind of failure: the
running build predated the change and wrote the old ten-station order, which
is how the check proved it was reading the live app rather than the source.
Both test orders were removed afterwards; the operator's own order is
untouched.

## P-G-2, the final build: 3.0.0 rebuilt from the screens, 2026-09-22

The candidate P-G-2 staged on 2026-09-21 did not contain Tuning, Labs or the
first-run screens; they were waiting on the operator's picks. The picks were
made, the screens were built (P-E-2, P-E-3, P-F-1), so this is the rebuild that
row was waiting for. **Still staged, not published.**

**The guarantees, again, on the tree as it is now.** `oss-guarantee.sh`
self-test first, quoted: "PASS: every check in the guarantee is proven able to
fail." Then the run: "PASS: 1145 file(s) would publish, every byte read, no
banned string, no commit history, and the Swift identity guard agrees."
`check-contract.py`: "clean, no drift".

**Notarized.** `GRUX_RELEASE=1 GRUX_NOTARIZE=1 ./build.sh` with the App Store
Connect API key: submission `8e02e884-5850-42b4-922d-d39047423a7f`, status
**Accepted**, "The staple and validate action worked!". The release app was NOT
installed, so the dev install and its permission grants are untouched.

**Verified from the staged zip, not from the build directory.** Unzipped fresh:
`spctl --assess` "accepted, source=Notarized Developer ID"; `stapler validate`
"The validate action worked!"; `codesign --verify --strict --deep` "valid on
disk, satisfies its Designated Requirement"; version 3.0.0, bundle
`com.gruxai.grux`.

**No TypeSafe key in the shipped bundle**, with the control seen first: the
real key was read from the Keychain into memory (never printed), planted into a
scratch copy of a bundle file and FOUND, which is what makes the zeros mean
something. Then, across the bundle's 13 files: the key value 0, its first 24
characters 0, the Keychain item's name 0. `ShippedBundleHygieneTests` 5 of 5,
none skipped.

**Staged** in `~/Downloads/Grux-3.0.0-candidate/`, outside the repository, with
the previous candidate moved aside rather than deleted
(`~/Downloads/superseded-candidates/Grux-3.0.0-candidate-rc1-20260922/`):

- `Grux-3.0.0-macOS-arm64.zip` and `Grux-macOS-arm64.zip`, the two names 1.2.1
  shipped under, 24,260,401 bytes, sha256 `6d2d1dd0d5951b1c85682545a1c7b9678da93c92102063849327413915c92d32`.
- `dotcomjack-grux-3.0.0.tgz` from `npm pack`, sha256 `369da7fa2ead1fbf...`,
  with `npm test` 11 of 11 passing.
- `RELEASE-NOTES-draft.md`, cut from the CHANGELOG entry, which was rewritten
  today: it still said Tuning, Labs and the first-run screens were "not in this
  build yet", which stopped being true, and it now carries them plus the three
  fixes from this session (the overheard-command bug, quieter room-talk
  approvals, Design Studio's key).
- `SHA256SUMS.txt`, regenerated.

**Nothing was published.** No tag was pushed, no GitHub release exists, nothing
went to npm, and gruxai.com is untouched. Suite 3082 executed, 9 skipped, 0
failures.
