import SwiftUI
import Combine

// MARK: - ShellStateAdapters
//
// Translates the existing scattered shell signals into ShellStateBus moments
// WITHOUT modifying any of the producing subsystems. Everything here is a
// read-only subscription to state those subsystems already publish:
//
//   SpeechEngine.$isSpeaking / $isBuffering   (TTS lifecycle)
//   WakeWordListener.$isListening             (wake mic)
//   AppState.$isThinking                      (chat round-trip)
//   AppState.$micMuted                        (orb tap hard-mute)
//   .gruxWakeDetected                         (wake word hit)
//   .gruxFocusEvent + AppState.lastVerdict    (focus watcher verdicts)
//   .gruxCommandV2RunStarted / RunFinished    (workflow engine)
//   AgentService.$jobs                        (agent swarm activity)
//
// Call ShellStateAdapters.shared.start() once at launch (see integration
// notes in GruxApp). start() is idempotent.

@MainActor
final class ShellStateAdapters {
    static let shared = ShellStateAdapters()

    // Stable source ids. The bus lets the owning source downgrade itself, so
    // each producer must publish under one consistent name.
    enum Source {
        static let speech = "speech"
        static let wake = "wake"
        static let chat = "chat"
        static let mic = "mic"
        static let focus = "focus"
        static let workflow = "workflow"
        static let agents = "agents"
    }

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        // TTS: speaking wins over everything below alert. On the falling
        // edge the same source downgrades back to idle, which the bus allows
        // regardless of hold.
        SpeechEngine.shared.$isSpeaking
            .removeDuplicates()
            .sink { speaking in
                Task { @MainActor in
                    if speaking {
                        ShellStateBus.shared.publish(
                            mode: .speaking, headline: "Speaking",
                            source: Source.speech, hold: 1.5
                        )
                    } else {
                        ShellStateBus.shared.publish(
                            mode: .idle, headline: "Idle", source: Source.speech
                        )
                    }
                }
            }
            .store(in: &cancellables)

        // TTS buffering reads as thinking (matches LaunchRootView, which
        // folds isBuffering into the speaking visual; thinking is the closer
        // semantic for "audio not out yet").
        SpeechEngine.shared.$isBuffering
            .removeDuplicates()
            .sink { buffering in
                Task { @MainActor in
                    guard buffering else { return }
                    ShellStateBus.shared.publish(
                        mode: .thinking, headline: "Preparing voice",
                        source: Source.speech, hold: 1.0
                    )
                }
            }
            .store(in: &cancellables)

        // Chat round-trip.
        AppState.shared.$isThinking
            .removeDuplicates()
            .sink { thinking in
                Task { @MainActor in
                    if thinking {
                        ShellStateBus.shared.publish(
                            mode: .thinking, headline: "Thinking",
                            source: Source.chat, hold: 1.0
                        )
                    } else {
                        ShellStateBus.shared.publish(
                            mode: .idle, headline: "Idle", source: Source.chat
                        )
                    }
                }
            }
            .store(in: &cancellables)

        // Wake-word mic.
        WakeWordListener.shared.$isListening
            .removeDuplicates()
            .sink { listening in
                Task { @MainActor in
                    if listening {
                        ShellStateBus.shared.publish(
                            mode: .listening, headline: "Listening",
                            source: Source.wake
                        )
                    } else {
                        ShellStateBus.shared.publish(
                            mode: .idle, headline: "Idle", source: Source.wake
                        )
                    }
                }
            }
            .store(in: &cancellables)

        // Hard mute from the orb tap. Idle-mode moment with an explicit
        // headline; views that render a dedicated muted orb keep doing so
        // off AppState.micMuted (see integration notes).
        AppState.shared.$micMuted
            .removeDuplicates()
            .dropFirst()
            .sink { muted in
                Task { @MainActor in
                    ShellStateBus.shared.publish(
                        mode: .idle,
                        headline: muted ? "Mic muted" : "Idle",
                        source: Source.mic
                    )
                }
            }
            .store(in: &cancellables)

        // Wake word hit: a short listening flash even before the listener
        // state machine flips.
        NotificationCenter.default.publisher(for: .gruxWakeDetected)
            .sink { _ in
                Task { @MainActor in
                    ShellStateBus.shared.publish(
                        mode: .listening, headline: "Wake word heard",
                        source: Source.wake, hold: 3.0
                    )
                }
            }
            .store(in: &cancellables)

        // Focus watcher verdicts. AppState posts .gruxFocusEvent after every
        // appendEvent; lastVerdict carries the classification.
        NotificationCenter.default.publisher(for: .gruxFocusEvent)
            .sink { _ in
                Task { @MainActor in
                    let state = AppState.shared
                    guard let verdict = state.lastVerdict else { return }
                    switch verdict {
                    case .onTask:
                        ShellStateBus.shared.publish(
                            mode: .onTask, headline: "On task",
                            detail: state.currentTask?.title ?? "",
                            source: Source.focus, hold: 20
                        )
                    case .drifting:
                        ShellStateBus.shared.publish(
                            mode: .drifting, headline: "Drifting",
                            detail: state.lastActiveApp,
                            source: Source.focus, hold: 20
                        )
                    case .offTask:
                        ShellStateBus.shared.publish(
                            mode: .alert, headline: "Off task",
                            detail: state.lastActiveApp,
                            source: Source.focus, hold: 20
                        )
                    case .ambiguous:
                        break
                    }
                }
            }
            .store(in: &cancellables)

        // Workflow engine (Commands V2). Run start and finish both post with
        // the run UUID as the notification object.
        NotificationCenter.default.publisher(for: .gruxCommandV2RunStarted)
            .sink { note in
                let runId = note.object as? UUID
                Task { @MainActor in
                    let name = runId.flatMap { CommandV2Engine.shared.run(id: $0)?.displayName }
                    ShellStateBus.shared.publish(
                        mode: .thinking,
                        headline: "Workflow running",
                        detail: name ?? "",
                        source: Source.workflow, hold: 6
                    )
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .gruxCommandV2RunFinished)
            .sink { note in
                let runId = note.object as? UUID
                Task { @MainActor in
                    let run = runId.flatMap { CommandV2Engine.shared.run(id: $0) }
                    let failed = run?.status == .failed
                    ShellStateBus.shared.publish(
                        mode: failed ? .alert : .onTask,
                        headline: failed ? "Workflow failed" : "Workflow finished",
                        detail: run?.displayName ?? "",
                        source: Source.workflow, hold: failed ? 8 : 5
                    )
                }
            }
            .store(in: &cancellables)

        // Agent swarm activity: any queued or running job reads as thinking.
        AgentService.shared.$jobs
            .map { jobs in jobs.contains { $0.status == .running || $0.status == .queued } }
            .removeDuplicates()
            .dropFirst()
            .sink { active in
                Task { @MainActor in
                    if active {
                        ShellStateBus.shared.publish(
                            mode: .thinking, headline: "Agents working",
                            source: Source.agents, hold: 4
                        )
                    } else {
                        ShellStateBus.shared.publish(
                            mode: .idle, headline: "Idle", source: Source.agents
                        )
                    }
                }
            }
            .store(in: &cancellables)
    }
}
