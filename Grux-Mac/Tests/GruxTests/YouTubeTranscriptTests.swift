import XCTest
@testable import Grux

// Item 20 (YouTube transcript ingestion) coverage. Pure parsing only: video
// ID extraction, watch-page captionTracks discovery, timedtext XML + json3
// parsing, title extraction, timestamp formatting, truncation, and the
// SemanticMemory chunker. All against canned fixtures; no test touches the
// network or yt-dlp.
final class YouTubeTranscriptTests: XCTestCase {

    // MARK: - Video ID extraction

    func test_extractVideoId_watchURL() {
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func test_extractVideoId_watchURL_withExtraParams() {
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PL123"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/watch?list=PL123&v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    func test_extractVideoId_shortLink() {
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ?t=30"), "dQw4w9WgXcQ")
    }

    func test_extractVideoId_shortsEmbedLive() {
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/shorts/abc-DEF_123"), "abc-DEF_123")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/embed/abc-DEF_123"), "abc-DEF_123")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/live/abc-DEF_123?feature=share"), "abc-DEF_123")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/v/abc-DEF_123"), "abc-DEF_123")
    }

    func test_extractVideoId_hostVariants() {
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://m.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ", "missing scheme should still parse")
    }

    func test_extractVideoId_bareId() {
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeTranscript.extractVideoId(from: "  dQw4w9WgXcQ  "), "dQw4w9WgXcQ", "should trim whitespace")
    }

    func test_extractVideoId_rejectsGarbage() {
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: ""))
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: "not a url"))
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: "https://vimeo.com/12345"))
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: "https://www.youtube.com/feed/subscriptions"))
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: "https://notyoutube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: "tooShort"))
        XCTAssertNil(YouTubeTranscript.extractVideoId(from: "waaaayTooLongToBeAVideoId"))
    }

    // MARK: - Timedtext XML parsing

    private let xmlFixture = """
    <?xml version="1.0" encoding="utf-8" ?><transcript>\
    <text start="0.08" dur="4.96">hello world</text>\
    <text start="5.04" dur="3.2">I&amp;#39;m testing &amp;quot;captions&amp;quot; &amp;amp; entities</text>\
    <text dur="2.0" start="8.24">attribute order &lt;b&gt;varies&lt;/b&gt;</text>\
    <text start="10.5" dur="1.0">   </text>\
    <text start="12.0">no duration attr</text>\
    </transcript>
    """

    func test_parseTimedTextXML_segmentsAndTimes() {
        let segs = YouTubeTranscript.parseTimedTextXML(xmlFixture)
        XCTAssertEqual(segs.count, 4, "blank segment should be dropped")
        XCTAssertEqual(segs[0].start, 0.08, accuracy: 0.001)
        XCTAssertEqual(segs[0].duration, 4.96, accuracy: 0.001)
        XCTAssertEqual(segs[0].text, "hello world")
    }

    func test_parseTimedTextXML_doubleEncodedEntities() {
        let segs = YouTubeTranscript.parseTimedTextXML(xmlFixture)
        XCTAssertEqual(segs[1].text, "I'm testing \"captions\" & entities")
    }

    func test_parseTimedTextXML_attributeOrderAndInnerTags() {
        let segs = YouTubeTranscript.parseTimedTextXML(xmlFixture)
        XCTAssertEqual(segs[2].start, 8.24, accuracy: 0.001)
        XCTAssertEqual(segs[2].text, "attribute order varies", "inner tags should strip after entity decode")
    }

    func test_parseTimedTextXML_missingDurationDefaultsToZero() {
        let segs = YouTubeTranscript.parseTimedTextXML(xmlFixture)
        XCTAssertEqual(segs[3].start, 12.0, accuracy: 0.001)
        XCTAssertEqual(segs[3].duration, 0.0, accuracy: 0.001)
    }

    func test_parseTimedTextXML_emptyAndJunkInput() {
        XCTAssertTrue(YouTubeTranscript.parseTimedTextXML("").isEmpty)
        XCTAssertTrue(YouTubeTranscript.parseTimedTextXML("<html>not timedtext</html>").isEmpty)
    }

    // MARK: - json3 parsing

    func test_parseJSON3_basic() {
        let json = """
        {"events":[
          {"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"hello "},{"utf8":"world"}]},
          {"tStartMs":2500,"dDurationMs":1500,"segs":[{"utf8":"\\n"}]},
          {"tStartMs":4000,"dDurationMs":3000,"segs":[{"utf8":"second line"}]},
          {"tStartMs":9000,"dDurationMs":1000}
        ]}
        """
        let segs = YouTubeTranscript.parseJSON3(Data(json.utf8))
        XCTAssertEqual(segs.count, 2, "whitespace-only and seg-less events should be dropped")
        XCTAssertEqual(segs[0].text, "hello world")
        XCTAssertEqual(segs[0].start, 0.0, accuracy: 0.001)
        XCTAssertEqual(segs[0].duration, 2.0, accuracy: 0.001)
        XCTAssertEqual(segs[1].text, "second line")
        XCTAssertEqual(segs[1].start, 4.0, accuracy: 0.001)
    }

    func test_parseJSON3_invalidData() {
        XCTAssertTrue(YouTubeTranscript.parseJSON3(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(YouTubeTranscript.parseJSON3(Data("{}".utf8)).isEmpty)
    }

    // MARK: - Watch page captionTracks discovery

    private let watchPageFixture = """
    <!DOCTYPE html><html><head>
    <meta property="og:title" content="Test Video &amp; Friends">
    <title>Test Video &amp; Friends - YouTube</title>
    </head><body><script>var ytInitialPlayerResponse = {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[\
    {"baseUrl":"https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ\\u0026lang=de","name":{"simpleText":"German"},"languageCode":"de","kind":"asr"},\
    {"baseUrl":"https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ\\u0026lang=en\\u0026kind=asr","name":{"simpleText":"English [auto]"},"languageCode":"en","kind":"asr"},\
    {"baseUrl":"https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ\\u0026lang=en","name":{"simpleText":"English ] tricky"},"languageCode":"en"}\
    ],"audioTracks":[]}}};</script></body></html>
    """

    func test_captionTracks_parsesAllTracks() {
        let tracks = YouTubeTranscript.captionTracks(fromWatchPage: watchPageFixture)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[0].languageCode, "de")
        XCTAssertEqual(tracks[0].kind, "asr")
    }

    func test_captionTracks_decodesEscapedAmpersands() {
        let tracks = YouTubeTranscript.captionTracks(fromWatchPage: watchPageFixture)
        XCTAssertEqual(tracks[0].baseUrl, "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=de", "\\u0026 must decode to &")
    }

    func test_captionTracks_bracketInsideStringDoesNotEndArray() {
        // Third track's name contains a ']' inside a JSON string; the
        // balanced scanner must not stop there.
        let tracks = YouTubeTranscript.captionTracks(fromWatchPage: watchPageFixture)
        XCTAssertEqual(tracks[2].languageCode, "en")
        XCTAssertEqual(tracks[2].kind, "")
    }

    func test_captionTracks_missingFromPage() {
        XCTAssertTrue(YouTubeTranscript.captionTracks(fromWatchPage: "<html>no captions here</html>").isEmpty)
    }

    func test_pickBestTrack_prefersManualEnglish() {
        let tracks = YouTubeTranscript.captionTracks(fromWatchPage: watchPageFixture)
        let best = YouTubeTranscript.pickBestTrack(tracks)
        XCTAssertEqual(best?.languageCode, "en")
        XCTAssertEqual(best?.kind, "", "manual English must beat auto-generated English")
    }

    func test_pickBestTrack_fallsBackToAsrEnglish_thenAny() {
        let asrEn = YouTubeTranscript.CaptionTrack(baseUrl: "u1", languageCode: "en", kind: "asr")
        let manualDe = YouTubeTranscript.CaptionTrack(baseUrl: "u2", languageCode: "de", kind: "")
        XCTAssertEqual(YouTubeTranscript.pickBestTrack([manualDe, asrEn])?.baseUrl, "u1", "asr English beats manual non-English")
        XCTAssertEqual(YouTubeTranscript.pickBestTrack([manualDe])?.baseUrl, "u2")
        XCTAssertNil(YouTubeTranscript.pickBestTrack([]))
    }

    // MARK: - Title extraction

    func test_videoTitle_fromOgTitle() {
        XCTAssertEqual(YouTubeTranscript.videoTitle(fromWatchPage: watchPageFixture), "Test Video & Friends")
    }

    func test_videoTitle_fallbackToTitleTag() {
        let html = "<html><head><title>Plain Title - YouTube</title></head></html>"
        XCTAssertEqual(YouTubeTranscript.videoTitle(fromWatchPage: html), "Plain Title")
    }

    func test_videoTitle_missing() {
        XCTAssertNil(YouTubeTranscript.videoTitle(fromWatchPage: "<html></html>"))
    }

    // MARK: - Formatting + truncation

    func test_formatTimestamp() {
        XCTAssertEqual(YouTubeTranscript.formatTimestamp(0), "0:00")
        XCTAssertEqual(YouTubeTranscript.formatTimestamp(65.7), "1:05")
        XCTAssertEqual(YouTubeTranscript.formatTimestamp(3599), "59:59")
        XCTAssertEqual(YouTubeTranscript.formatTimestamp(3725), "1:02:05")
        XCTAssertEqual(YouTubeTranscript.formatTimestamp(-5), "0:00", "negative clamps to zero")
    }

    func test_transcriptResult_textShapes() {
        let result = YouTubeTranscriptResult(
            videoId: "dQw4w9WgXcQ",
            title: "T",
            segments: [
                YouTubeCaptionSegment(start: 0, duration: 2, text: "hello"),
                YouTubeCaptionSegment(start: 62, duration: 2, text: "world")
            ],
            source: "timedtext-xml"
        )
        XCTAssertEqual(result.plainText, "hello world")
        XCTAssertEqual(result.textWithTimestamps, "[0:00] hello\n[1:02] world")
    }

    func test_truncated_underLimitUnchanged() {
        let text = "short transcript"
        XCTAssertEqual(YouTubeTranscript.truncated(text, limit: 50_000), text)
    }

    func test_truncated_cutsOnLineBoundaryWithNotice() {
        let lines = (0..<100).map { "[0:\(String(format: "%02d", $0 % 60))] line \($0) of the transcript" }
        let text = lines.joined(separator: "\n")
        let out = YouTubeTranscript.truncated(text, limit: 300)
        XCTAssertLessThan(out.count, text.count)
        XCTAssertTrue(out.contains("[transcript truncated:"))
        // The kept body should end exactly at a line boundary (no split words).
        let body = out.components(separatedBy: "\n\n[transcript truncated:").first ?? ""
        XCTAssertTrue(lines.contains(body.components(separatedBy: "\n").last ?? ""), "last kept line must be a complete original line")
    }

    // MARK: - Entity decoding

    func test_decodeHTMLEntities_namedAndNumeric() {
        XCTAssertEqual(YouTubeTranscript.decodeHTMLEntities("a &lt;b&gt; &quot;c&quot; &#39;d&#39; &#x27;e&#x27; &amp; f"), "a <b> \"c\" 'd' 'e' & f")
    }

    func test_decodeHTMLEntities_doublePassHandlesDoubleEncoding() {
        let once = YouTubeTranscript.decodeHTMLEntities("I&amp;#39;m")
        XCTAssertEqual(YouTubeTranscript.decodeHTMLEntities(once), "I'm")
    }

    // MARK: - Memory chunker

    func test_chunkTranscript_respectsSizeAndCap() {
        let words = (0..<500).map { "word\($0)" }.joined(separator: " ")
        let chunks = YouTubeTool.chunkTranscript(words, chunkChars: 100, maxChunks: 3)
        XCTAssertEqual(chunks.count, 3, "cap must hold")
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, 100)
            XCTAssertFalse(c.hasPrefix(" "))
            XCTAssertFalse(c.hasSuffix(" "))
        }
    }

    func test_chunkTranscript_shortInputSingleChunk() {
        let chunks = YouTubeTool.chunkTranscript("just a few words", chunkChars: 700, maxChunks: 16)
        XCTAssertEqual(chunks, ["just a few words"])
        XCTAssertTrue(YouTubeTool.chunkTranscript("", chunkChars: 700, maxChunks: 16).isEmpty)
    }
}
