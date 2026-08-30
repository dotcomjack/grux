//
//  CreativeActions.swift
//  Grux Creative Studio - extensible per-asset action registry
//
//  One data-driven list of things you can do to a rendered asset. Live actions
//  execute today; "coming soon" actions render disabled with a tasteful Soon tag
//  so the surface is built out and new functions snap in by adding a case.
//

import Foundation

enum StudioAction: String, CaseIterable, Identifiable, Sendable {
    // Live
    case animate
    case approve
    case reject
    case exportAspects
    case draftSocial
    // Coming soon (foundation stubs, future tasks)
    case storyboard
    case upscale
    case variations
    case collection
    case bgSwap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .animate: return "Animate"
        case .approve: return "Approve"
        case .reject: return "Reject"
        case .exportAspects: return "Export aspects"
        case .draftSocial: return "Draft to social"
        case .storyboard: return "Send to storyboard"
        case .upscale: return "Upscale"
        case .variations: return "Make variations"
        case .collection: return "Add to collection"
        case .bgSwap: return "Background swap"
        }
    }

    var icon: String {
        switch self {
        case .animate: return "film"
        case .approve: return "checkmark.seal"
        case .reject: return "xmark.seal"
        case .exportAspects: return "rectangle.on.rectangle.angled"
        case .draftSocial: return "paperplane"
        case .storyboard: return "rectangle.split.3x1"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        case .variations: return "square.on.square.dashed"
        case .collection: return "folder.badge.plus"
        case .bgSwap: return "wand.and.stars"
        }
    }

    var isLive: Bool {
        switch self {
        case .animate, .approve, .reject, .exportAspects, .draftSocial: return true
        default: return false
        }
    }

    static var live: [StudioAction] { allCases.filter { $0.isLive } }
    static var comingSoon: [StudioAction] { allCases.filter { !$0.isLive } }
}
