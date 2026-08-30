import XCTest
@testable import Grux

/// Every route Media Studio calls is a configured base joined to a path, and
/// the base is PASTED BY A PERSON into a defaults key.
///
/// A trailing slash is an ordinary thing to find in a pasted URL, and the
/// naive concat every call site used turned one into "http://host//api/...".
/// Strict routers 404 that path, so a healthy render service failed every
/// render, mini-list, approve and draft-from-image, and the notice's own probe
/// counted the 404 as proof the service was listening and well. The join rule
/// has one home, `PrivateServiceFetch.join`, and `imageServiceURLs` is how the
/// render service reaches it.
final class CreativeServiceURLTests: XCTestCase {

    private let key = "grux.creative.imageServiceBaseURLs"

    /// Runs `body` with the image-service key forced to a value, restoring
    /// whatever this desk had afterwards.
    private func withBases(_ value: String, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: key)
        defaults.set(value, forKey: key)
        body()
        if let original {
            defaults.set(original, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testATrailingSlashBaseStillAsksForTheRealRoute() {
        withBases("http://mini.local:3847/") {
            XCTAssertEqual(CreativeEngine.imageServiceURLs("/api/images/render"),
                           ["http://mini.local:3847/api/images/render"],
                "the pasted trailing slash survived into the route, and a strict router "
                + "404s the doubled slash, so every render on that install failed while "
                + "the service was healthy")
        }
    }

    /// The control: a base WITHOUT a trailing slash is untouched, so the fix
    /// is a trim rather than a rewrite of everybody's configuration.
    func testABaseWithNoTrailingSlashIsUnchanged() {
        withBases("http://mini.local:3847") {
            XCTAssertEqual(CreativeEngine.imageServiceURLs("/api/images/render"),
                           ["http://mini.local:3847/api/images/render"])
        }
    }

    /// Precedence order is the failover order, and a query string is part of
    /// the route (the scene and sku lists are read that way), so neither may
    /// be disturbed by the join.
    func testEveryConfiguredBaseIsJoinedInOrderIncludingQueryRoutes() {
        withBases("http://a.local:3847/, http://b.local:3847") {
            XCTAssertEqual(CreativeEngine.imageServiceURLs("/api/images/skus?brand=examplebrand"),
                           ["http://a.local:3847/api/images/skus?brand=examplebrand",
                            "http://b.local:3847/api/images/skus?brand=examplebrand"],
                "the base list lost its order or its query, so failover walks a "
                + "different list than the one the user configured")
        }
    }

    /// Nothing configured is the shipped default and stays an empty list: the
    /// callers already read that as "not configured".
    func testNoConfiguredBaseYieldsNoURLs() {
        withBases("") {
            XCTAssertTrue(CreativeEngine.imageServiceURLs("/api/images/render").isEmpty,
                "an unconfigured install produced a route to call, which is a network "
                + "request nobody asked for")
        }
    }
}
