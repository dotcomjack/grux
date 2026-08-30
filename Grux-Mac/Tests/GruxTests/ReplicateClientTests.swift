import XCTest
@testable import Grux

/// Pure parsing and mapping tests for the Replicate predictions client. No live network:
/// every case feeds fixture JSON in the shapes Replicate's API returns through the static
/// helpers, plus the aspect mapping and the env override.
///
/// Replaces FalClientTests. Coverage is deliberately a superset rather than a translation,
/// because Replicate has two behaviours fal did not: `output` is polymorphic, and a
/// model-side failure arrives as a terminal STATUS rather than as an HTTP error.
final class ReplicateClientTests: XCTestCase {

    // MARK: - The prediction envelope

    func testParsePredictionCarriesStatusAndPollURL() throws {
        let json = Data("""
        {
          "id": "gm3qorzdhgbfurvjtvhg6dckhu",
          "status": "starting",
          "output": null,
          "error": null,
          "urls": {
            "get": "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu",
            "cancel": "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu/cancel"
          }
        }
        """.utf8)
        let p = try ReplicateClient.parsePrediction(json)
        XCTAssertEqual(p.id, "gm3qorzdhgbfurvjtvhg6dckhu")
        XCTAssertEqual(p.status, "starting")
        XCTAssertEqual(p.getURL, "https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu")
        XCTAssertNil(p.error)
    }

    /// A response with no `urls` block is tolerated: the client falls back to the documented
    /// /v1/predictions/<id> path, so nil here must not throw.
    func testParsePredictionWithoutURLsIsStillUsable() throws {
        let p = try ReplicateClient.parsePrediction(Data(#"{"id":"abc","status":"processing"}"#.utf8))
        XCTAssertEqual(p.id, "abc")
        XCTAssertNil(p.getURL)
    }

    /// `error` is documented as null on success and at least one model reports it as an
    /// OBJECT rather than a string. A hard String decode would throw on a prediction that
    /// actually succeeded, which is the worst possible place to fail.
    func testANonStringErrorFieldDoesNotSinkASucceededPrediction() throws {
        let json = Data("""
        {"id":"abc","status":"succeeded","output":["https://x/1.jpg"],
         "error":{"detail":"something structured"}}
        """.utf8)
        let p = try ReplicateClient.parsePrediction(json)
        XCTAssertEqual(p.status, "succeeded")
        XCTAssertNil(p.error, "a structured error field should read as absent, never throw")
        XCTAssertEqual(try ReplicateClient.outputURLs(json), ["https://x/1.jpg"])
    }

    func testAPayloadWithNoStatusIsADecodeFailure() {
        XCTAssertThrowsError(try ReplicateClient.parsePrediction(Data(#"{"id":"abc"}"#.utf8))) { err in
            guard case ReplicateError.decoding = err else {
                return XCTFail("expected .decoding, got \(err)")
            }
        }
    }

    // MARK: - The status lifecycle

    /// Every documented status, from Replicate's lifecycle page rather than from memory.
    func testTheWholeDocumentedLifecycleIsClassified() {
        XCTAssertEqual(ReplicateClient.outcome(of: "starting"),   .pending)
        XCTAssertEqual(ReplicateClient.outcome(of: "processing"), .pending)
        XCTAssertEqual(ReplicateClient.outcome(of: "succeeded"),  .succeeded)
        XCTAssertEqual(ReplicateClient.outcome(of: "failed"),     .failed)
        XCTAssertEqual(ReplicateClient.outcome(of: "canceled"),   .failed)
        XCTAssertEqual(ReplicateClient.outcome(of: "aborted"),    .failed,
                       "aborted means it exceeded its deadline BEFORE starting. Treating it "
                       + "as pending would spin the poll loop for the full 120 seconds and "
                       + "then report a timeout that hides the real reason")
    }

    /// Both spellings of cancelled, because the wire has used both and a client that only
    /// knows one hangs on the other.
    func testBothSpellingsOfCancelledAreTerminal() {
        XCTAssertEqual(ReplicateClient.outcome(of: "cancelled"), .failed)
        XCTAssertEqual(ReplicateClient.outcome(of: "CANCELED"), .failed, "and case does not matter")
    }

    /// An unknown status counts as PENDING on purpose: a vendor adding a new non-terminal
    /// state should make Grux wait, not make it declare a failure that did not happen.
    func testAnUnknownStatusMakesTheClientWaitRatherThanGuess() {
        XCTAssertEqual(ReplicateClient.outcome(of: "queued"), .pending)
        XCTAssertEqual(ReplicateClient.outcome(of: ""), .pending)
    }

    // MARK: - The polymorphic output field

    /// Replicate's own guide says it plainly: "Some image models return an array of output
    /// files, others just a single file." A typed decode of one shape throws on the other,
    /// which is why this reads raw JSON.
    func testOutputReadsBothShapes() throws {
        let many = Data(#"{"status":"succeeded","output":["https://x/1.jpg","https://x/2.jpg"]}"#.utf8)
        XCTAssertEqual(try ReplicateClient.outputURLs(many), ["https://x/1.jpg", "https://x/2.jpg"])

        let one = Data(#"{"status":"succeeded","output":"https://x/only.jpg"}"#.utf8)
        XCTAssertEqual(try ReplicateClient.outputURLs(one), ["https://x/only.jpg"])
    }

    func testAnAbsentOrEmptyOutputIsADecodeFailure() {
        for body in [#"{"status":"succeeded","output":null}"#,
                     #"{"status":"succeeded"}"#,
                     #"{"status":"succeeded","output":[]}"#,
                     #"{"status":"succeeded","output":""}"#,
                     #"{"status":"succeeded","output":[1,2,3]}"#] {
            XCTAssertThrowsError(try ReplicateClient.outputURLs(Data(body.utf8)),
                                 "accepted \(body)") { err in
                guard case ReplicateError.decoding = err else {
                    return XCTFail("expected .decoding for \(body), got \(err)")
                }
            }
        }
    }

    // MARK: - Aspect mapping

    /// Every value has to be one of the ratios flux accepts BY NAME. A string flux does not
    /// recognise falls into its "custom" branch, which then wants explicit width and height
    /// that this client does not send, so the model would silently render the default size.
    func testEveryAspectMapsToARatioFluxAcceptsByName() {
        let accepted: Set<String> = ["1:1", "16:9", "21:9", "3:2", "2:3", "4:5", "5:4", "9:16", "9:21"]
        for aspect in [AspectPreset.square, .portrait45, .vertical, .landscape] {
            let ratio = ReplicateClient.aspectRatio(for: aspect)
            XCTAssertTrue(accepted.contains(ratio), "\(aspect) mapped to \(ratio), which flux "
                          + "does not accept by name and would treat as custom")
        }
        XCTAssertEqual(ReplicateClient.aspectRatio(for: .square), "1:1")
        XCTAssertEqual(ReplicateClient.aspectRatio(for: .portrait45), "4:5")
        XCTAssertEqual(ReplicateClient.aspectRatio(for: .vertical), "9:16")
        XCTAssertEqual(ReplicateClient.aspectRatio(for: .landscape), "16:9")
    }

    /// Distinct, because a mapping that collapsed two presets onto one ratio would render
    /// the wrong shape for one of them and nothing would say so.
    func testTheFourPresetsAreFourDifferentRatios() {
        let all = [AspectPreset.square, .portrait45, .vertical, .landscape]
            .map(ReplicateClient.aspectRatio(for:))
        XCTAssertEqual(Set(all).count, all.count, "two presets share a ratio: \(all)")
    }

    // MARK: - Model resolution

    func testTheDefaultModelIsUsedWhenNothingOverridesIt() {
        XCTAssertEqual(ReplicateModels.imageModel(env: [:]), "black-forest-labs/flux-dev")
        XCTAssertEqual(ReplicateModels.imageModel(env: ["GRUX_REPLICATE_IMAGE_MODEL": "   "]),
                       "black-forest-labs/flux-dev",
                       "a blank override is not an override")
    }

    func testTheEnvironmentCanRepointTheModelWithoutARebuild() {
        XCTAssertEqual(
            ReplicateModels.imageModel(env: ["GRUX_REPLICATE_IMAGE_MODEL": "stability-ai/sdxl"]),
            "stability-ai/sdxl")
    }

    /// The model id is `owner/name`, because it is interpolated into
    /// /v1/models/<owner>/<name>/predictions. A bare name would build a 404 URL.
    func testTheDefaultModelIsInOwnerSlashNameForm() {
        let parts = ReplicateModels.defaultImage.split(separator: "/")
        XCTAssertEqual(parts.count, 2, "\(ReplicateModels.defaultImage) is not owner/name, so "
                       + "the predictions URL it builds cannot resolve")
    }

    // MARK: - Content type

    func testContentTypeFallsBackToTheExtensionWhenTheServerDoesNotSay() {
        XCTAssertEqual(ReplicateClient.contentType(forPathExtension: "png"), "image/png")
        XCTAssertEqual(ReplicateClient.contentType(forPathExtension: "WEBP"), "image/webp")
        XCTAssertEqual(ReplicateClient.contentType(forPathExtension: "jpg"), "image/jpeg")
        XCTAssertEqual(ReplicateClient.contentType(forPathExtension: ""), "image/jpeg")
    }

    /// And the extension the bundle writes comes back out of the content type, so a png
    /// stays a png on disk.
    func testTheOnDiskExtensionFollowsTheContentType() {
        func ext(_ ct: String) -> String {
            ReplicateImage(data: Data(), contentType: ct, width: nil, height: nil).fileExtension
        }
        XCTAssertEqual(ext("image/png"), "png")
        XCTAssertEqual(ext("image/webp"), "webp")
        XCTAssertEqual(ext("image/jpeg"), "jpg")
        XCTAssertEqual(ext("application/octet-stream"), "jpg")
    }
}
