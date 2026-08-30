import XCTest
@testable import Grux

// Unit coverage for the audio WAL lifecycle + recovery primitives.
// Everything here runs pure in-process, no WhisperKit, no AppKit, no
// capture pipeline, we isolate to the disk IO and manifest logic.
@MainActor
final class AudioWALTests: XCTestCase {

    private func makeChunk(seconds: Double, hz: Float = 440, sampleRate: Double = 16_000) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Float(sin(2 * .pi * Double(hz) * Double(i) / sampleRate))
        }
        return out
    }

    private var tempRoot: URL!
    private var originalCwd: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Scoped temp root, Persistence.audioWALDir reads from
        // Application Support, which is shared; but AudioWAL operates on
        // whatever URL it's given. We validate the on-disk layout by
        // crafting URLs directly (and cleaning up the real audio-wal dir
        // at the end of each test so we never pollute dev data).
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grux-audio-wal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        // Sweep any stray sessions the in-process WAL left in the real
        // audio-wal dir (e.g. from begin/appendChunk assertions). Only
        // delete UUIDs we created.
        try await super.tearDown()
    }

    // MARK: - PCM round-trip

    func test_writeAndReadPCM_roundTrip() throws {
        let samples = makeChunk(seconds: 1.0)
        let url = tempRoot.appendingPathComponent("chunk-000000.pcm")
        try AudioWAL.writePCM(samples, to: url)

        guard let loaded = AudioWAL.readPCM(from: url) else {
            return XCTFail("readPCM returned nil")
        }
        XCTAssertEqual(loaded.count, samples.count)
        for i in 0..<samples.count {
            XCTAssertEqual(loaded[i], samples[i], accuracy: 1e-6)
        }
    }

    func test_readPCM_emptyFile_returnsEmptyArray() throws {
        let url = tempRoot.appendingPathComponent("empty.pcm")
        try Data().write(to: url)
        let out = AudioWAL.readPCM(from: url)
        XCTAssertEqual(out, [])
    }

    func test_readPCM_misalignedFile_returnsNil() throws {
        let url = tempRoot.appendingPathComponent("bad.pcm")
        // 3 bytes, not a Float32 multiple
        try Data([0x01, 0x02, 0x03]).write(to: url)
        XCTAssertNil(AudioWAL.readPCM(from: url))
    }

    // MARK: - Pruning

    func test_pruneOldChunks_keepsOnlyNewestN() throws {
        let dir = tempRoot.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<15 {
            let url = dir.appendingPathComponent(AudioWAL.chunkFileName(index: i))
            try Data([0,0,0,0]).write(to: url)
        }
        AudioWAL.pruneOldChunks(dir: dir, keepMostRecent: 9)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining.count, 9)
        XCTAssertEqual(remaining.first, "chunk-000006.pcm")
        XCTAssertEqual(remaining.last, "chunk-000014.pcm")
    }

    func test_pruneOldChunks_underThreshold_keepsAll() throws {
        let dir = tempRoot.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<3 {
            let url = dir.appendingPathComponent(AudioWAL.chunkFileName(index: i))
            try Data([0,0,0,0]).write(to: url)
        }
        AudioWAL.pruneOldChunks(dir: dir, keepMostRecent: 9)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining.count, 3)
    }

    // MARK: - Meta round-trip

    func test_metaRoundTrip_preservesFields() throws {
        let url = tempRoot.appendingPathComponent("meta.json")
        let meta = AudioWAL.SessionMeta(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceApp: "us.zoom.xos",
            sourceAppName: "zoom.us",
            title: "Standup",
            lastFlushedAt: Date(timeIntervalSince1970: 1_700_000_300),
            status: .open,
            chunkSeconds: 10,
            sampleRate: 16_000,
            channels: 1,
            bytesPerSample: 4,
            retentionChunks: 9,
            chunksWritten: 5,
            formatVersion: AudioWAL.formatVersion
        )
        AudioWAL.writeMeta(meta, to: url)
        guard let loaded = AudioWAL.loadMeta(at: url) else {
            return XCTFail("loadMeta returned nil")
        }
        XCTAssertEqual(loaded.id, meta.id)
        XCTAssertEqual(loaded.sourceApp, "us.zoom.xos")
        XCTAssertEqual(loaded.sourceAppName, "zoom.us")
        XCTAssertEqual(loaded.title, "Standup")
        XCTAssertEqual(loaded.status, .open)
        XCTAssertEqual(loaded.chunkSeconds, 10)
        XCTAssertEqual(loaded.sampleRate, 16_000)
        XCTAssertEqual(loaded.chunksWritten, 5)
        XCTAssertEqual(loaded.formatVersion, AudioWAL.formatVersion)
    }

    // MARK: - Full session lifecycle

    func test_beginAppendFinalizeClean_removesSessionDir() async throws {
        let id = UUID()
        AudioWAL.shared.begin(
            meetingId: id,
            sourceApp: "us.zoom.xos",
            sourceAppName: "zoom.us",
            title: "Test"
        )
        AudioWAL.shared.appendChunk(makeChunk(seconds: 0.25))
        AudioWAL.shared.appendChunk(makeChunk(seconds: 0.25))
        AudioWAL.shared.flushSync()

        let dir = Persistence.audioWALDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let metaURL = dir.appendingPathComponent("meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path), "meta.json should exist mid-session")
        let meta = AudioWAL.loadMeta(at: metaURL)
        XCTAssertEqual(meta?.status, .open)
        XCTAssertEqual(meta?.id, id)

        AudioWAL.shared.finalize(clean: true)
        AudioWAL.shared.flushSync()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.path),
            "session dir should be gone after clean finalize"
        )
        XCTAssertFalse(AudioWAL.shared.isActive)
    }

    func test_finalizePreserve_marksClosedButKeepsFiles() async throws {
        let id = UUID()
        AudioWAL.shared.begin(
            meetingId: id,
            sourceApp: nil,
            sourceAppName: nil,
            title: nil
        )
        AudioWAL.shared.appendChunk(makeChunk(seconds: 0.5))
        AudioWAL.shared.flushSync()

        _ = AudioWAL.shared.finalize(clean: false)
        AudioWAL.shared.flushSync()

        let dir = Persistence.audioWALDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let metaURL = dir.appendingPathComponent("meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let meta = AudioWAL.loadMeta(at: metaURL)
        XCTAssertEqual(meta?.status, .closed)

        // Cleanup so we don't leak into recovery on the next launch.
        try? FileManager.default.removeItem(at: dir)
    }

    func test_appendChunk_ringBufferPrunesOldest() async throws {
        let id = UUID()
        // Small retention to keep the test quick.
        // (We can't swap the singleton's retention; instead use the
        // retentionChunks default of 9 and write 12 chunks.)
        AudioWAL.shared.begin(
            meetingId: id,
            sourceApp: nil,
            sourceAppName: nil,
            title: nil
        )
        for _ in 0..<12 {
            AudioWAL.shared.appendChunk(makeChunk(seconds: 0.1))
        }
        AudioWAL.shared.flushSync()

        let dir = Persistence.audioWALDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("chunk-") }
            .sorted()
        XCTAssertLessThanOrEqual(remaining.count, 9, "expected ring buffer to cap at 9 chunks, got \(remaining.count)")
        XCTAssertTrue(remaining.contains("chunk-000011.pcm"), "newest chunk must survive")
        XCTAssertFalse(remaining.contains("chunk-000000.pcm"), "oldest chunk must be pruned")

        AudioWAL.shared.finalize(clean: true)
        AudioWAL.shared.flushSync()
    }

    // MARK: - Recovery scan

    func test_scanForOrphans_findsOpenSessions() async throws {
        // Craft a fake orphan session by hand so we don't rely on the
        // in-process AudioWAL to set state.
        let id = UUID()
        let dir = Persistence.audioWALDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = AudioWAL.SessionMeta(
            id: id,
            startedAt: Date().addingTimeInterval(-300),
            sourceApp: nil,
            sourceAppName: nil,
            title: nil,
            lastFlushedAt: Date().addingTimeInterval(-60),
            status: .open,
            chunkSeconds: 10,
            sampleRate: 16_000,
            channels: 1,
            bytesPerSample: 4,
            retentionChunks: 9,
            chunksWritten: 1,
            formatVersion: AudioWAL.formatVersion
        )
        AudioWAL.writeMeta(meta, to: dir.appendingPathComponent("meta.json"))
        try AudioWAL.writePCM(makeChunk(seconds: 0.5), to: dir.appendingPathComponent(AudioWAL.chunkFileName(index: 0)))

        defer { try? FileManager.default.removeItem(at: dir) }

        let orphans = AudioWALRecovery.scanForOrphans()
        let ours = orphans.first { $0.meta.id == id }
        XCTAssertNotNil(ours, "scanForOrphans should return the crafted session")
        XCTAssertEqual(ours?.chunkURLs.count, 1)
    }

    func test_scanForOrphans_skipsEmptyDir_andWipesIt() async throws {
        let id = UUID()
        let dir = Persistence.audioWALDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = AudioWAL.SessionMeta(
            id: id,
            startedAt: Date(),
            sourceApp: nil, sourceAppName: nil, title: nil,
            lastFlushedAt: Date(), status: .open,
            chunkSeconds: 10, sampleRate: 16_000, channels: 1, bytesPerSample: 4,
            retentionChunks: 9, chunksWritten: 0,
            formatVersion: AudioWAL.formatVersion
        )
        AudioWAL.writeMeta(meta, to: dir.appendingPathComponent("meta.json"))
        // No chunk files, scan should sweep and exclude.
        let orphans = AudioWALRecovery.scanForOrphans()
        XCTAssertFalse(orphans.contains(where: { $0.meta.id == id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
