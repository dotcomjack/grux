import Foundation

// WHICH SERVER A TURN ACTUALLY REACHES, as a base URL.
//
// Hung off the registry from its own file the same way the validation surface at
// the bottom of CustomEndpointStore.swift is, because it answers a routing
// question and every input it reads is one `resolvedRouting` already reads.
//
// It exists because there are now TWO base URLs on this machine and only one of
// them is the route. `config.ollamaBaseURL` used to be the whole answer: every
// non-Anthropic backend was built from it, so anything that needed to judge a
// turn by its URL could read that field and be right. The explicit provider
// selection falsified that. `active()` builds `customBackend(id)` from the saved
// endpoint's own `ep.baseURL`, `apiKey()` resolves the credential from
// `ep.baseURL`, and nothing re-syncs the config field when the selection moves
// or clears the selection when the field is edited. So the two can name
// different servers for the rest of an install, and a caller reading the field
// is answering a question nobody asked.
//
// Measured on this tree: add a hosted endpoint and press Use (which writes BOTH
// values together, so it is correct at that moment), then edit Settings, Models,
// Base URL back to http://localhost:11434 to point the health poller and the
// cookbook at the local server again. From then on every turn bills the hosted
// endpoint with the hosted key while the config field says localhost. The cost
// meter read the field, priced the turn `.local`, and put "$0 estimated (local,
// free)" under the composer on a billed send.
extension ModelRegistry {

    // The base URL the turn `resolvedRouting(provider:modelOverride:)` hands back
    // will POST to, or nil when that turn goes to Anthropic (which has no compat
    // base URL, and is never priced off one).
    //
    // `provider` is the PRESET PIN, the same optional string `resolvedRouting`
    // takes, and it is deliberately NOT the "local" tag `ChatService` publishes
    // for cost. That tag says "local" for two different routes: a preset pinned
    // "local", which `resolvedRouting` builds from `config.ollamaBaseURL` and
    // never falls back to Anthropic, and the registry's own selection, which for
    // `.custom(id)` is the endpoint's own URL. Reading the pin is what keeps
    // those apart. Switching on the tag instead would answer the endpoint's URL
    // for a turn the pin sent to the local server, which reopens the same $0
    // failure from the other side: pin "local" with a hosted config field and a
    // loopback endpoint saved is a billed turn that would read free.
    func routedBaseURL(provider: String?) -> String? {
        switch provider {
        case "anthropic":
            return nil
        case "local":
            return AppState.shared.config.ollamaBaseURL
        default:
            switch resolvedProvider {
            case .anthropic:
                return nil
            case .local:
                return AppState.shared.config.ollamaBaseURL
            case .custom(let id):
                // The same fallback `apiKey()` uses, so the URL and the
                // credential can never be read off two different records.
                return CustomEndpointStore.shared.endpoint(id: id)?.baseURL
                    ?? AppState.shared.config.ollamaBaseURL
            }
        }
    }
}
