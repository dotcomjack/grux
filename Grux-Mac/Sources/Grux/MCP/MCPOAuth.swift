import AppKit
import AuthenticationServices
import Foundation

// OAuth helper for MCP servers whose upstream services require a browser
// grant (Linear, Notion-hosted, etc). v1 posture: most servers should ship
// with plain API keys pasted into the env fields in Settings; this helper
// exists for the ones that cannot.
//
// Flow: caller builds the provider's authorization URL (with a custom-scheme
// redirect like grux://oauth; the grux scheme is registered in Info.plist
// under CFBundleURLTypes), authorize() runs it through
// ASWebAuthenticationSession, and the caller exchanges the returned code for
// a token, then persists it with storeToken(). Tokens live in the Keychain
// (service com.gruxai.grux, account mcp.oauth.<serverID>), never in JSON, and
// are surfaced to the server process as an env value at spawn time by adding
// the env key in Settings with the token value.

enum MCPOAuthError: LocalizedError {
    case failedToStart
    case canceled
    case noCallbackURL

    var errorDescription: String? {
        switch self {
        case .failedToStart: return "could not start the OAuth browser session"
        case .canceled: return "OAuth sign-in was canceled"
        case .noCallbackURL: return "OAuth session ended without a callback URL"
        }
    }
}

@MainActor
final class MCPOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuth()

    // Canonical callback scheme. Must stay in sync with the CFBundleURLTypes
    // entry in Info.plist (CFBundleURLSchemes: grux). Redirect URIs look like
    // grux://oauth?code=...; pass this to authorize() unless a provider
    // demands a different registered scheme.
    static let callbackScheme = "grux"

    private var activeSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
    }

    // Runs the browser grant and returns the redirect callback URL. The
    // caller extracts the code/token with queryValue(_:in:).
    func authorize(authorizationURL: URL, callbackScheme: String = MCPOAuth.callbackScheme) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: callbackScheme) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                    cont.resume(throwing: MCPOAuthError.canceled)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(throwing: MCPOAuthError.noCallbackURL)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                cont.resume(throwing: MCPOAuthError.failedToStart)
            }
        }
    }

    func cancel() {
        activeSession?.cancel()
        activeSession = nil
    }

    // MARK: - Token storage (Keychain)

    static func tokenAccount(serverID: UUID) -> String {
        "mcp.oauth.\(serverID.uuidString)"
    }

    static func storeToken(_ token: String, serverID: UUID) {
        _ = CustomEndpointStore.keychainSet(account: tokenAccount(serverID: serverID), value: token)
    }

    // Empty string means no token, matching the KeychainStore.get contract.
    static func token(serverID: UUID) -> String {
        CustomEndpointStore.keychainGet(account: tokenAccount(serverID: serverID))
    }

    static func deleteToken(serverID: UUID) {
        CustomEndpointStore.keychainDelete(account: tokenAccount(serverID: serverID))
    }

    // Pulls a named query parameter (code, token, state) out of a callback URL.
    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // AuthenticationServices calls this on the main thread; assert that
        // and hand back the key window so the grant sheet anchors to Grux.
        MainActor.assumeIsolated {
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                ?? ASPresentationAnchor()
        }
    }
}
