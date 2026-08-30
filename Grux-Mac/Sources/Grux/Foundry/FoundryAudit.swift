// Audit vocabulary for the Foundry. One of the five hard rails: every
// self-change is recorded as one of these actions in the Self-Upgrade
// tab timeline.
enum FoundryAudit {

    // What happened to the proposal.
    enum Action: Sendable {
        case proposed
        case accepted
        case rejected
        case buildStarted
        case verifyStarted
        case landed
        case rolledBack
        case tierPromoted
        case tierDemoted
    }
}
