import SwiftUI

/// True when a surface is drawn inside the Command Panel's pane. Chat reads
/// it to fold its threads sidebar (Task 7).
private struct HostedInPaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hostedInPane: Bool {
        get { self[HostedInPaneKey.self] }
        set { self[HostedInPaneKey.self] = newValue }
    }
}
