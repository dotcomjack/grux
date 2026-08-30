//
//  CreativeStudioSupport.swift
//  Grux Creative Studio - shared support: thumbnail cache + gallery filters
//
//  Pulled out of CreativeEngine.swift so the gallery has a cheap, cached image
//  path (was decoding full-res NSImage on every body pass) and a single source
//  of truth for the library filter chips.
//

import Foundation
import AppKit
import SwiftUI
import ImageIO

/// Decodes downsampled thumbnails once and caches them, keyed by path + size.
/// Replaces repeated full-res `NSImage(contentsOfFile:)` calls in the gallery
/// and sibling strip, which were the main scroll-perf cost as the library grew.
@MainActor
final class ImageThumbCache {
    static let shared = ImageThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    /// A downsampled thumbnail at roughly `maxPixel` on the long edge. Returns
    /// nil if the file is missing or not decodable.
    func thumb(at path: String, maxPixel: CGFloat) -> NSImage? {
        let key = "\(path)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}

/// Library filter chips. Keeps the gallery organized instead of one flat list.
enum GalleryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case videos = "Videos"
    case approved = "Approved"
    case needsImage = "Needs image"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .videos: return "play.rectangle.fill"
        case .approved: return "checkmark.seal.fill"
        case .needsImage: return "photo.badge.plus"
        }
    }

    /// Does a bundle belong under this filter?
    func matches(_ b: CreativeBundle) -> Bool {
        switch self {
        case .all: return true
        case .videos: return b.videoPath != nil
        case .approved: return b.approval == .approved
        case .needsImage: return b.localImagePath == nil
        }
    }
}
