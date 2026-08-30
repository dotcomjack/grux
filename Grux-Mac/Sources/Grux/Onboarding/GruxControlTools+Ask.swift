import Foundation
import GruxMCPCore

// MARK: - grux_ask

/// One mutable bit, so the poll loop below can tell "the turn ended" from "the turn is still
/// going".
///
/// `Task` has no non blocking way to ask whether it finished, and awaiting the task instead
/// would give up the deadline the whole shape exists to hold. Read and written only on the
/// main actor, in the same synchronous step as the thread it is paired with, so the pair
/// cannot be observed half updated.
@MainActor
private final class AskTurn {
    var finished = false
}

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// How long to wait for the assistant turn before answering without one.
    ///
    /// Shorter than the 180 seconds `grux ask` gives the socket, on purpose. Whichever
    /// deadline fires first writes the sentence somebody reads, and only this side knows
    /// enough to say the turn is still running and where its answer will appear. The
    /// client's own timeout sentence is about an app that is busy starting up, which here
    /// would be a wrong story told confidently.
    private static let askDeadlineSeconds: TimeInterval = 150

    /// Ask chat one question and come back with the answer.
    ///
    /// ## Waiting is the whole job
    ///
    /// `ChatService.send` is `async` and does write the assistant turn to the thread before
    /// it returns, so awaiting it is most of the wait. It is not all of it. Two of its paths
    /// finish having written no answer at all, and a caller that read "send returned" as
    /// "the question was answered" would hand back an empty string and call it a reply. That
    /// is the defect this handler exists to not have. So it watches the THREAD for the turn
    /// rather than the call, and reports what it actually found there.
    ///
    /// ## Eight endings, and each one says which it is
    ///
    /// `not_ready` (nothing is attached to chat), `answered`, `blocked` (the model refused
    /// in a way only a person can clear, out of credit being the one that happens),
    /// `failed` (a retry can work), `repeat` (the same question seconds ago, which the app
    /// coalesces), `unanswered` (the question turned into a confirmation card),
    /// `still_working` (the deadline came first), and a refusal for an empty question.
    /// Structured rather than prose because the CLI has to lay the answer out, dim the
    /// machine detail and pick between three exit codes, and none of those survive being
    /// parsed back out of a sentence.
    static func ask(text: String) async -> [String: Any] {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return MCPWire.textFailure("grux_ask needs a question, and will not invent one. "
                + "Everything after the command is the question.")
        }

        // REFUSE BEFORE SPENDING, AND BEFORE WRITING TO THE THREAD. `ChatService.send` makes
        // this same check and answers it with an assistant bubble, which is right inside the
        // app and wrong here twice over: it would leave a turn nobody asked for in the user's
        // thread, and it would hand this caller a sentence about Settings dressed up as a
        // reply to their question. Asking first also lets the CLI exit 2, the code that means
        // somebody has to do something on this Mac before any invocation can work.
        let readiness = ChatReadiness.current()
        guard readiness.canSend else {
            return askResult(state: "not_ready",
                             message: readiness.headline + ". " + readiness.detail,
                             seconds: 0)
        }

        let started = Date()
        let turn = AskTurn()
        Task {
            await ChatService.shared.send(userText: question)
            turn.finished = true
        }

        // The three reads inside one iteration happen with no `await` between them, on the
        // main actor, which is the same actor `send` appends on. So "there is an answer" and
        // "the turn is over" are read from one consistent moment and a turn cannot slip
        // through the gap between them.
        var answer: String?
        var ranOutOfTime = false
        while true {
            if let found = askAnswer(to: question, since: started) { answer = found; break }
            if turn.finished { break }
            if Date().timeIntervalSince(started) >= Self.askDeadlineSeconds {
                ranOutOfTime = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let elapsed = Date().timeIntervalSince(started)

        if let answer {
            // A FAILED TURN IS ALSO AN ASSISTANT BUBBLE, and it reads "warning glyph, then a
            // sentence about billing". Handing that back as an answer would be a lie with a
            // model's confidence behind it. `send` clears `chatRecovery` at the top of every
            // turn it actually starts, so a recovery still standing here, carrying this
            // question, belongs to THIS turn and not to an older one.
            //
            // The message goes through untouched. It is the app's own designed sentence for
            // the failure it classified, so an exhausted balance arrives as what is wrong and
            // what to do about it rather than as a status code or a connection error.
            if let recovery = AppState.shared.chatRecovery, recovery.retryText == question {
                WakeLog.shared.log("grux_ask: the turn failed, \(recovery.kind)")
                return askResult(state: askNeedsAPerson(recovery) ? "blocked" : "failed",
                                 message: recovery.message,
                                 seconds: elapsed)
            }
            return askResult(state: "answered", answer: answer, seconds: elapsed)
        }

        if ranOutOfTime {
            WakeLog.shared.log("grux_ask: no answer inside \(Int(Self.askDeadlineSeconds))s")
            return askResult(
                state: "still_working",
                message: "Grux is still working on this after "
                       + "\(Int(Self.askDeadlineSeconds)) seconds, which is longer than a "
                       + "model answer usually takes. The turn was not cancelled, so its "
                       + "answer will appear in the Grux chat window when it lands.",
                seconds: elapsed)
        }

        // THE TURN ENDED AND WROTE NOTHING. Two paths in `send` do that, and they are told
        // apart by whether the USER turn made it into the thread: the repeat guard returns
        // before appending it and is the only thing in `send` that does, so this is read off
        // the thread rather than guessed at from the wording of the question.
        guard askUserTurn(question, in: AppState.shared.chat, since: started) != nil else {
            return askResult(
                state: "repeat",
                message: "Grux read this as a repeat of the question it took a moment ago "
                       + "and coalesced the two, so nothing went to a model and nothing was "
                       + "spent. The answer to the first copy lands in the same thread. Ask "
                       + "again in a few seconds if you want a second one.",
                seconds: elapsed)
        }
        return askResult(
            state: "unanswered",
            message: "Grux read this as something to do rather than something to answer, so "
                   + "it put a confirmation card in the Grux window instead of replying. "
                   + "Nothing went to a model. Accept or dismiss the card in Grux, or ask "
                   + "again in words that are a question.",
            seconds: elapsed)
    }

    /// The first assistant turn standing AFTER this question in the thread.
    ///
    /// Anchored to the question's own position rather than to a timestamp window, because
    /// the window alone would let a turn from another surface, dictation or the app's own
    /// composer, be handed back as the answer to a question the CLI asked. Anchored, and
    /// FIRST rather than last, one send writes one assistant turn and it is the next one.
    private static func askAnswer(to question: String, since: Date) -> String? {
        let chat = AppState.shared.chat
        guard let mine = askUserTurn(question, in: chat, since: since) else { return nil }
        return chat[(mine + 1)...].first { $0.role == .assistant }?.content
    }

    private static func askUserTurn(_ question: String,
                                    in chat: [ChatMessage],
                                    since: Date) -> Int? {
        chat.firstIndex {
            $0.role == .user && $0.timestamp >= since && $0.content == question
        }
    }

    /// Whether this failure is one that no retry can clear on its own.
    ///
    /// The distinction is what the CLI turns into exit 2 rather than exit 1, so it has to be
    /// exact. An exhausted balance and a spent usage cap both need somebody at this Mac; a
    /// per minute rate limit clears by itself, and sending a script off to go and fix a
    /// billing page over one would be wrong. Those three share the one recovery kind, so the
    /// message constants are compared whole rather than sniffed for a substring.
    private static func askNeedsAPerson(_ recovery: ChatRecovery) -> Bool {
        switch recovery.kind {
        case .offlineNoModel:
            return true
        case .limitHit:
            return recovery.message == ChatCredentialHelp.creditExhausted
                || recovery.message == ChatCredentialHelp.usageLimitReached
        case .network, .generic:
            return false
        }
    }

    /// Which backend actually served the turn, named the way the person named it.
    ///
    /// A custom endpoint answers with the name they gave it rather than the word "custom",
    /// because "OpenRouter" is the fact somebody wants under an answer and "custom" is the
    /// shape of a menu.
    private static func askProvider() -> String {
        switch ModelRegistry.shared.resolvedProvider {
        case .anthropic:
            return "anthropic"
        case .local:
            return "local"
        case .custom(let id):
            return CustomEndpointStore.shared.endpoint(id: id)?.name ?? "custom endpoint"
        }
    }

    /// One shape for all seven of the reachable outcomes, so a caller reads `state` once and
    /// never has to tell two different replies apart by what keys they happen to carry.
    private static func askResult(state: String,
                                  message: String? = nil,
                                  answer: String? = nil,
                                  seconds: TimeInterval) -> [String: Any] {
        var out: [String: Any] = [
            "state": state,
            "model": ModelRegistry.shared.modelId(),
            "provider": askProvider(),
            "seconds": (seconds * 10).rounded() / 10,
        ]
        if let message { out["message"] = message }
        if let answer { out["answer"] = answer }
        if let thread = AppState.shared.activeThreadId { out["thread"] = thread.uuidString }
        return MCPWire.textResult(jsonText(out))
    }
}
