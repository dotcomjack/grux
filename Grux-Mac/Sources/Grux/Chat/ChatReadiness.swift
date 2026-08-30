import Foundation

/// Whether chat can send anything at all, and what to say when it cannot.
///
/// THE FAILURE THIS CLOSES. `ModelRegistry.resolvedRouting` falls back to
/// Anthropic when no local model is discovered and returns `apiKey()` whatever
/// it holds. With no key stored and no local server that is an EMPTY key, so
/// every send left the app, hit the network, and came back a provider error.
/// The user could retry forever and the message they saw talked about status
/// codes and conversation length. Neither was the problem. Nothing was attached.
///
/// The defect is not the wording. It is that a request which cannot possibly
/// succeed was sent, so the app had to guess at the answer from a status code
/// instead of stating the thing it already knew before it started.
///
/// TWO WAYS OUT, ALWAYS BOTH. A user with no key has not necessarily decided to
/// buy one, and running a local model needs no key and no account, which is the
/// reason this app can work with neither. Offering only "add a key" would turn
/// a free path into an invisible one.
///
/// AND THREE ROUTES, NOT TWO. Once a provider became an explicit stored choice,
/// this file's own reading of `offlineMode` and `local != nil` stopped being the
/// same question the router answers. A saved custom endpoint, selected and
/// holding its own key, routes every turn and needs no Anthropic key at all, and
/// readiness still called that `.needsModel`: Send stayed disabled and the copy
/// said Grux was not using a model it was in fact about to use. So the inputs
/// here are now the router's own two answers, `activeProvider` (what was chosen)
/// and `resolvedProvider` (what can actually serve right now), rather than a
/// second guess at the same thing.
enum ChatReadiness: Equatable {

    /// A turn has somewhere to go. All three routes land here and none of them
    /// needs its own case, because there is nothing for the composer to say:
    /// Anthropic with a key, a discovered local model the router is using, and a
    /// selected custom endpoint (which carries its own credential, so an empty
    /// Anthropic key is not an obstacle on that route).
    case ready

    /// Nothing is attached: no key, and no local model discovered.
    case needsModel

    /// Ollama is up and Grux can see it, but offline mode is off so the router
    /// will not use it. The fix is one switch, and telling this user to buy an
    /// API key would be actively wrong.
    case localModelFoundButNotRouted

    /// The user pinned offline and there is no local server to run. A key does
    /// NOT rescue this, and must not: `resolvedRouting` already refuses to
    /// silently fall back to Anthropic for a local-pinned preset, on the
    /// grounds that the user explicitly chose local. Readiness agrees with that
    /// rather than reporting green because a cloud key happens to exist.
    case offlinePinnedButNoLocalModel

    var canSend: Bool { self == .ready }

    var headline: String {
        switch self {
        case .ready:
            return ""
        case .localModelFoundButNotRouted:
            return "A local model is running but Grux is not using it"
        case .needsModel:
            return "Chat has no model to talk to"
        case .offlinePinnedButNoLocalModel:
            return "Offline mode is on and no local model is running"
        }
    }

    /// Names both routes and where to go. Deliberately carries no status code
    /// and offers no retry, because there is nothing to retry: the send never
    /// happened and would fail identically the next time.
    var detail: String {
        switch self {
        case .ready:
            return ""
        case .localModelFoundButNotRouted:
            return "Turn on offline mode in Settings and Grux will use it. It costs nothing and needs no key. "
                 + "You can also add an API key instead."
        case .needsModel:
            // NAMES WHICH CREDENTIAL. Grux has two and they are easy to confuse
            // because both end in the word Claude: this key, which powers chat,
            // and the claude.ai sign-in that AccountSwitcher runs to give the
            // agent CLI a subscription for terminal sessions. Reported 2026-08-23:
            // a user in this exact state ended up on a Claude sign-in page
            // linking a terminal and still had nothing powering Grux.
            return "Run a local model and Grux uses it with no key and no account, "
                 + "or add your own API key. Both are in Settings. Signing the agent CLI "
                 + "in to Claude is a different thing: that powers terminal sessions, not chat."
        case .offlinePinnedButNoLocalModel:
            return "Start your local model server, or turn offline mode off to use an API key instead. "
                 + "Both are in Settings."
        }
    }

    /// The rule, as a pure function of the facts that decide it.
    ///
    /// Split from `current()` because `current()` reads the Keychain and the
    /// discovered backend, so on a machine that already has credentials, which
    /// includes every machine this is developed on, a test of it can only ever
    /// observe "ready". Same reason `CapabilityResolver.keyPrecedence` exists.
    ///
    /// `chosenProvider` is `ModelRegistry.activeProvider` and `routedProvider`
    /// is `ModelRegistry.resolvedProvider`. Taking BOTH is what lets one rule
    /// answer two different questions: whether a turn can go out at all, which
    /// only the resolved route knows, and what to say when it cannot, which only
    /// the choice explains. A resolved route of Anthropic means either that is
    /// what the user picked or that the router had to fall back, and those two
    /// need different sentences.
    static func evaluate(hasAnthropicKey: Bool,
                         localModelAvailable: Bool,
                         chosenProvider: ActiveProvider,
                         routedProvider: ActiveProvider) -> ChatReadiness {
        // A ROUTE THAT IS NOT ANTHROPIC NEEDS NO ANTHROPIC KEY.
        //
        // `resolvedProvider` answers `.local` or `.custom` only when the backend
        // behind that choice exists right now, so once it has, there is nothing
        // left for readiness to check. This is the whole of the custom-endpoint
        // fix: routing worked and the UI refused to send, because readiness was
        // still asking about an offline switch that a hosted endpoint has no
        // reason to touch.
        if routedProvider != .anthropic { return .ready }

        // The route is Anthropic. Whether that was the choice or a fallback is
        // what decides which sentence the user gets.
        switch chosenProvider {
        case .local:
            // Local was chosen and nothing is running. A key does NOT rescue
            // this and must not: `resolvedRouting` already refuses to serve a
            // local-pinned preset from the cloud, on the grounds that the user
            // explicitly chose local.
            return .offlinePinnedButNoLocalModel
        case .custom:
            // The selected endpoint no longer resolves (deleted, or a stored id
            // from an older install), so the router fell back. A key still
            // carries the turn; without one this is the same dead end as having
            // nothing attached at all.
            return hasAnthropicKey ? .ready : .needsModel
        case .anthropic:
            // A DISCOVERED LOCAL MODEL IS NOT A ROUTED ONE.
            //
            // This used to read `if localModelAvailable || hasAnthropicKey`,
            // which disagreed with the router: with Anthropic chosen, the turn
            // goes to Anthropic no matter what Ollama is doing. Discovery runs
            // unconditionally at launch, so the ordinary local setup, Ollama up
            // and no API key, reported READY, enabled Send, and sent to
            // Anthropic with an empty key. The guard missed the exact state it
            // was built for, and the user was told to add a key while the model
            // that would have served them was already running.
            if hasAnthropicKey { return .ready }
            return localModelAvailable ? .localModelFoundButNotRouted : .needsModel
        }
    }

    /// The three-fact form, for an install that has never chosen a provider.
    ///
    /// It derives the pair above exactly as `ModelRegistry` does with nothing
    /// stored: `activeProvider` is `offlineMode ? .local : .anthropic`, and
    /// `resolvedProvider` downgrades a local choice with no discovered server
    /// back to Anthropic. Deriving rather than restating is the point, so there
    /// stays ONE rule to change.
    static func evaluate(hasAnthropicKey: Bool,
                         localModelAvailable: Bool,
                         offlineMode: Bool) -> ChatReadiness {
        let chosen: ActiveProvider = offlineMode ? .local : .anthropic
        let routed: ActiveProvider = (chosen == .local && localModelAvailable) ? .local : .anthropic
        return evaluate(hasAnthropicKey: hasAnthropicKey,
                        localModelAvailable: localModelAvailable,
                        chosenProvider: chosen,
                        routedProvider: routed)
    }

    @MainActor
    static func current() -> ChatReadiness {
        let registry = ModelRegistry.shared
        return evaluate(
            hasAnthropicKey: !AppState.shared.anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            localModelAvailable: registry.local != nil,
            chosenProvider: registry.activeProvider,
            routedProvider: registry.resolvedProvider)
    }
}
