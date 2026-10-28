import Foundation

/// A folder the namer watches, and which rule picks its candidates.
///
/// Measured 2026-10-27: the owner's MacBook saves screenshots to
/// `~/Documents/`, not the Desktop, so the screenshot folder is a folder full
/// of files a person named. There only a screen capture is a candidate. In
/// Downloads only a machine-made name is. When the two are the same folder,
/// both rules apply, each to its own files.
struct FileNamingFolder: Equatable {
    let url: URL
    /// Screen captures here are candidates: the capture xattr AND a name that
    /// still reads as a capture stamp.
    var screenshots: Bool
    /// Images and PDFs with a machine-made name here are candidates.
    var downloads: Bool
    /// The name a capture starts with on this Mac (`FileNamingRules.capturePrefixes`).
    var capturePrefixes: [String] = FileNamingRules.defaultCapturePrefixes
}

/// Which files the namer may touch. Pure, apart from the two readers at the
/// bottom (the screenshot defaults and one xattr), so the table that decides
/// "a person named this, leave it alone" is tested line by line.
enum FileNamingRules {

    // MARK: - Kind

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"]

    static func kind(ofExtension ext: String) -> FileNamingKind? {
        let lower = ext.lowercased()
        if lower == "pdf" { return .pdf }
        return imageExtensions.contains(lower) ? .image : nil
    }

    // MARK: - Partial and hidden

    /// A download in progress, or a screenshot before macOS gives it its name.
    /// Measured 2026-10-27: a capture lands as `..name-XXXX`, then `.name`,
    /// and takes its final name about 0.7 s after it starts. Chrome writes
    /// `.crdownload`, Safari a `.download` bundle.
    static let partialSuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp", ".opdownload"]

    static func isPartialOrHidden(_ fileName: String) -> Bool {
        if fileName.hasPrefix(".") { return true }
        let lower = fileName.lowercased()
        return partialSuffixes.contains { lower.hasSuffix($0) }
    }

    // MARK: - Looks machine-made

    /// A trailing copy counter: `document (3)`, `document(3)`, `file-2`.
    private static let copyCounter = try! NSRegularExpression(pattern: #"(\s*\(\d+\)|-\d{1,3})$"#)

    /// A generic word alone, or followed only by digits and separators.
    private static let genericWord = try! NSRegularExpression(
        pattern: #"^(document|download|file|image|img|scan|untitled|unknown|attachment|invoice|receipt|statement|export|print|photo|pic|screenshot|screen shot|pxl|dsc|dcim)[0-9_\- ]*$"#)

    /// A camera or capture app's stamp at the start of the name, each with a
    /// digit after it: without one, `Screen Recording Policy` read as made by
    /// a machine (review 2026-10-28).
    private static let stamp = try! NSRegularExpression(
        pattern: #"^(img[_-][0-9]|pxl_[0-9]|dsc[f_]?[0-9]|screenshot[ _-]?[0-9]|screen shot [0-9]|cleanshot [0-9]|screen recording [0-9])"#)

    /// A UUID or hash: the WHOLE stem, separators removed, is 16 or more hex
    /// characters. Anchored, because a run inside a longer name is a person's
    /// order or tracking number (`Acme order 112-1234567-1234567` held a
    /// 17 digit run once its hyphens were gone, review 2026-10-28).
    private static let hexStem = try! NSRegularExpression(pattern: #"^[0-9a-f]{16,}$"#)

    private static let separators: Set<Character> = ["-", "_", ".", " "]

    /// Whether `baseName` (no extension) reads as named by a clock, a camera or
    /// a server rather than by a person. Leans to false: renaming a file a
    /// person named is the worst thing this feature can do, so anything that
    /// could have been typed (`Lease renewal 2027`, `taxes`, `Q3 deck final`)
    /// stays false.
    static func looksMachineMade(_ baseName: String) -> Bool {
        var name = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = replace(copyCounter, in: name, with: "")
        guard !name.isEmpty else { return false }
        let lower = name.lowercased()

        if matches(genericWord, lower) { return true }
        // Nothing but digits and separators: `20261027_094103`, `1693`.
        if !name.contains(where: \.isLetter) { return true }
        // A hash has to hold a digit, so a string of words made only of the
        // letters a to f is not taken for one.
        let joined = String(lower.filter { !separators.contains($0) })
        if matches(hexStem, joined), joined.contains(where: \.isNumber) { return true }
        if matches(stamp, lower) { return true }
        return isCodeLike(name)
    }

    /// One token like `C0855-1693` or `INV-000123`: digits are 40% or more of
    /// its characters, and every run of letters is a code's prefix, not a
    /// word: one letter, or two or three capitals. Letter runs, not
    /// separator segments, because `taxes2025`, `resume2024` and `lease2027`
    /// have no separator and are plainly typed (review 2026-10-28). Two more
    /// limits lean false: at least 5 characters (`Q3` is somebody's quarter)
    /// and no space (`Acme 12345` is two tokens). `W2-2025` and `Q4-2025` do
    /// read as codes by this rule, a trade the 2026-10-28 review ruling
    /// accepted.
    static func isCodeLike(_ name: String) -> Bool {
        guard !name.contains(" ") else { return false }
        let chars = name.filter { !separators.contains($0) }
        guard chars.count >= 5 else { return false }
        let digits = chars.filter(\.isNumber).count
        guard Double(digits) / Double(chars.count) >= 0.4 else { return false }
        let letterRuns = name.split(whereSeparator: { !$0.isLetter })
        return letterRuns.allSatisfy { run in
            run.count == 1 || (run.count <= 3 && run.allSatisfy(\.isUppercase))
        }
    }

    // MARK: - Looks like a capture

    /// What macOS names a capture when the `name` default is not set.
    /// `Screen Shot` is the spelling from before macOS 10.14.
    static let defaultCapturePrefixes = ["Screenshot", "Screen Shot"]

    /// The capture name prefix from the `com.apple.screencapture` defaults:
    /// the person's own `name` when they set one, else the two system ones.
    static func capturePrefixes(defaults: [String: Any]) -> [String] {
        let custom = (defaults["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? defaultCapturePrefixes : [custom]
    }

    /// The whole shape of a capture's name in every language macOS ships, end
    /// to end: a prefix with no digits (and maybe no space, `截屏2026-10-27`),
    /// the date, up to 12 characters of words, the time (`9.41.03`, `09:41`),
    /// up to 8 characters of AM or PM marker, and maybe a ` (2)` counter.
    /// `Bildschirmfoto 2026-10-27 um 09.41.03` matches. A prefix and a date
    /// alone matched `Expense report 2026-10-28 copy`, a capture the person
    /// had named and then copied, and that copy was renamed (review
    /// 2026-10-28).
    private static let localizedCapture = try! NSRegularExpression(
        pattern: #"^[^0-9]+[0-9]{4}-[0-9]{2}-[0-9]{2}[^0-9]{0,12}[0-9]{1,2}[.:][0-9]{2}(?:[.:][0-9]{2})?[^0-9]{0,8}(?: \([0-9]+\))?$"#)

    /// Whether `baseName` still reads as the name macOS gave a capture: a
    /// prefix, a space, then a digit (`Screenshot 2026-10-27 at 9.41.03 AM`),
    /// or the whole localized shape. The capture xattr survives a rename,
    /// so the mark alone cannot tell `Bug repro.png` (a capture a person
    /// named) from a fresh one (review 2026-10-28). The dated form is what
    /// keeps a Mac in another language working: its captures carry a
    /// localized prefix that is not in the `name` default, and with the
    /// English prefixes only, no capture was ever named there (review
    /// 2026-10-28).
    static func looksLikeCapture(_ baseName: String, prefixes: [String]) -> Bool {
        for prefix in prefixes where !prefix.isEmpty {
            guard let range = baseName.range(of: prefix + " ", options: [.anchored, .caseInsensitive]) else { continue }
            if baseName[range.upperBound...].first?.isNumber == true { return true }
        }
        return matches(localizedCapture, baseName)
    }

    // MARK: - Pairs

    /// Whether another file in the folder belongs with this one: the same
    /// stem with a different extension (a Live Photo's `IMG_4471.HEIC` beside
    /// `IMG_4471.MOV`, a raw and its JPEG), or a sidecar (`IMG_4471.xmp`,
    /// `IMG_4471.aae`, or `IMG_0012.jpg.xmp` as darktable writes it). Photos
    /// and photo editors pair those by name, so renaming one half splits them
    /// (review 2026-10-28). A partner still downloading counts: its partial
    /// suffix comes off first, so `IMG_4471.MOV.crdownload` pairs with the
    /// HEIC that finished before it. `others` are the folder's other names.
    static func hasPair(_ fileName: String, among others: [String]) -> Bool {
        let lowerName = fileName.lowercased()
        let ns = lowerName as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        let sidecars: Set<String> = [lowerName + ".xmp", stem + ".xmp", stem + ".aae"]
        return others.contains { other in
            var o = other.lowercased()
            if sidecars.contains(o) { return true }
            if let suffix = partialSuffixes.first(where: { o.hasSuffix($0) }) { o.removeLast(suffix.count) }
            let on = o as NSString
            return o != lowerName && !on.pathExtension.isEmpty
                && on.deletingPathExtension == stem && on.pathExtension != ext
        }
    }

    // MARK: - Candidacy

    enum Candidacy: Equatable {
        case candidate(FileNamingKind)
        /// Left alone, and counted in the status under this reason.
        case skip(FileNamingSkip)
        /// Not a finished file yet (hidden or partial): not counted, because
        /// it reappears under its final name.
        case ignore
    }

    /// The name and folder rules, in the spec's order. The size and regular
    /// file checks need the disk, so the service makes them.
    static func candidacy(fileName: String, in folder: FileNamingFolder,
                          isScreenCapture: () -> Bool) -> Candidacy {
        if isPartialOrHidden(fileName) { return .ignore }
        let ns = fileName as NSString
        guard let kind = kind(ofExtension: ns.pathExtension) else { return .skip(.unsupported) }
        // The file system tool's deny list, on the whole name and on the stem:
        // no image or PDF extension is on it, so `credentials.png` is only
        // caught by its stem.
        if FilesystemTool.matchesDeniedBasename(fileName)
            || FilesystemTool.matchesDeniedBasename(ns.deletingPathExtension) { return .skip(.unsupported) }
        let stem = ns.deletingPathExtension
        if folder.screenshots,
           looksLikeCapture(stem, prefixes: folder.capturePrefixes) || looksMachineMade(stem),
           isScreenCapture() { return .candidate(kind) }
        if folder.downloads && looksMachineMade(stem) { return .candidate(kind) }
        return .skip(.humanName)
    }

    // MARK: - The screenshot folder

    /// Where macOS saves a screenshot, from the `com.apple.screencapture`
    /// defaults. The stored location is a tilde path (`~/Documents/` on the
    /// owner's MacBook, measured 2026-10-27), with the Desktop when the key is
    /// absent. A target other than `file` (the clipboard, Preview, Mail)
    /// writes no file, so there is no folder to watch.
    static func screenshotFolder(defaults: [String: Any], home: URL) -> URL? {
        if let target = defaults["target"] as? String, !target.isEmpty, target.lowercased() != "file" {
            return nil
        }
        let raw = (defaults["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return home.appendingPathComponent("Desktop", isDirectory: true) }
        if raw == "~" || raw == "~/" { return home }
        if raw.hasPrefix("~/") {
            var rest = String(raw.dropFirst(2))
            while rest.hasSuffix("/") { rest.removeLast() }
            return rest.isEmpty ? home : home.appendingPathComponent(rest, isDirectory: true)
        }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL }
        return nil
    }

    /// The screencapture keys that decide the folder and the capture name,
    /// read fresh: a person can change the location in the Screenshot app at
    /// any time, so they are re-read on every arm.
    static func screenshotDefaults() -> [String: Any] {
        let app = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(app)
        var out: [String: Any] = [:]
        for key in ["location", "target", "name"] {
            if let value = CFPreferencesCopyAppValue(key as CFString, app) { out[key] = value }
        }
        return out
    }

    /// The folders to watch on this Mac: the screenshot folder and Downloads,
    /// merged when they are the same. A folder that does not exist is kept:
    /// its listing fails, so it is retried and armed when it appears, as for a
    /// folder macOS has not opened yet. Filtering it out here dropped it for
    /// the whole arm, and the existence check itself, for a folder inside
    /// Desktop or Documents, waits on the permission dialog (review
    /// 2026-10-28). Nothing here reads inside a folder.
    static func watchedFolders(fileManager fm: FileManager = .default) -> [FileNamingFolder] {
        let home = fm.homeDirectoryForCurrentUser
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads", isDirectory: true)
        return watchedFolders(defaults: screenshotDefaults(), home: home, downloads: downloads)
    }

    /// The pure half of `watchedFolders`, so a test can hand in folders that
    /// do not exist and see them kept.
    static func watchedFolders(defaults: [String: Any], home: URL, downloads: URL) -> [FileNamingFolder] {
        var out: [FileNamingFolder] = []
        if let shots = screenshotFolder(defaults: defaults, home: home) {
            out.append(FileNamingFolder(url: shots, screenshots: true, downloads: false,
                                        capturePrefixes: capturePrefixes(defaults: defaults)))
        }
        if let i = out.firstIndex(where: { $0.url.standardizedFileURL.path == downloads.standardizedFileURL.path }) {
            out[i].downloads = true
        } else {
            out.append(FileNamingFolder(url: downloads, screenshots: false, downloads: true))
        }
        return out
    }

    // MARK: - The screen capture mark

    /// The xattr macOS puts on a keyboard or Screenshot app capture. Measured
    /// 2026-10-27: a Cmd-Shift-3 file carries it (mdls reads `1`); a
    /// `screencapture -x <path>` file does not. More reliable than the
    /// `Screenshot ` name prefix, which is localized and which a person can
    /// change.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    static func isScreenCapture(_ url: URL) -> Bool {
        let path = url.path
        let size = getxattr(path, screenCaptureAttribute, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, screenCaptureAttribute, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return false }
        let value = try? PropertyListSerialization.propertyList(from: data.prefix(read), options: [], format: nil)
        if let flag = value as? NSNumber { return flag.boolValue }
        // Present but not a number: macOS sets this key only on captures.
        return true
    }

    // MARK: - Regex helpers

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
