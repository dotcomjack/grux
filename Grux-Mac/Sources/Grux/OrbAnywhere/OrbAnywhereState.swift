import Foundation
import SwiftUI
import Combine

// Visibility + ephemeral context for the always-on-top floating Orb.
// `isVisible` is the RUNTIME mirror of `AppState.config.orbAnywhereEnabled`.
// Keeping it here (rather than on AppState) means panel show/hide logic has
// one observable source of truth without tangling into the 283-line AppState.
@MainActor
final class OrbAnywhereState: ObservableObject {
    static let shared = OrbAnywhereState()

    @Published var isVisible: Bool = false

    private init() {}
}
