import XCTest
import GruxShellCore
@testable import Grux

// BrandSystemGenerator: every active registry brand yields a system, the baked
// house law lands in each one, and slugs are hygienic. Network-free: registry
// projects are decoded from a JSON fixture, never fetched.
//
// No brand roster is compiled into the app, so there is nothing to assert about
// built-in brands. What these tests pin instead is the contract that replaced
// it: brands come from the registry, an injected style reaches the tokens, and
// a brand with no style and no support contact still gets a lawful system.
@MainActor
final class BrandSystemGeneratorTests: XCTestCase {

    // Decode a fixture roster the way the registry client would, so we exercise
    // the real project shape without touching the network or its internal init.
    private func fixtureProjects() throws -> [RemoteProject] {
        let json = """
        [
          {"id":"1","name":"Acme Botanicals","slug":"acme","rootPath":"/x","status":"active"},
          {"id":"2","name":"Some Registry Brand","slug":"some-registry","rootPath":"/y","status":"active"},
          {"id":"3","name":"Paused Thing","slug":"paused-thing","rootPath":"/z","status":"paused"},
          {"id":"4","name":"Weird Brand 2","slug":"Weird Brand 2","rootPath":"/w","status":"active"}
        ]
        """
        return try JSONDecoder().decode([RemoteProject].self, from: Data(json.utf8))
    }

    func test_everyActiveRegistryBrandYieldsASystem() throws {
        let generator = BrandSystemGenerator()
        let systems = generator.systems(projects: try fixtureProjects())

        let slugs = Set(systems.map { $0.slug })
        XCTAssertTrue(slugs.isSuperset(of: ["acme", "some-registry", "weird-brand-2"]))
        // Paused projects are excluded.
        XCTAssertFalse(slugs.contains("paused-thing"))
        XCTAssertEqual(systems.count, 3, "3 active registry brands, no brands compiled in")

        // Every system carries the baked law sections.
        for system in systems {
            XCTAssertFalse(system.name.isEmpty)
            XCTAssertNotNil(system.sections[.components], "\(system.slug) is missing components")
            XCTAssertNotNil(system.sections[.voice], "\(system.slug) is missing voice")
            XCTAssertNotNil(system.sections[.antiPatterns], "\(system.slug) is missing anti-patterns")
        }
    }

    // An empty registry is a supported state: no brands are compiled in, so a
    // machine with nothing registered generates nothing and does not throw.
    func test_emptyRegistryGeneratesNothingRatherThanFailing() {
        let systems = BrandSystemGenerator().systems(projects: [])
        XCTAssertTrue(systems.isEmpty, "no registry means no systems, reported rather than invented")
    }

    func test_styledBrand_carriesTightScale_noDashLaw_supportEmail_andPalette() throws {
        let style = BrandStyle(
            slug: "acme",
            paletteWords: ["warm amber", "natural cream"],
            paletteHex: ["#FFB86B", "#FBF7EF"],
            styleNotes: "clean editorial look, soft daylight, fresh and uncluttered"
        )
        let generator = BrandSystemGenerator(
            styleProvider: { $0 == "acme" ? style : BrandStyle.generic(slug: $0) },
            supportEmailProvider: { $0 == "acme" ? "support@example.com" : "" }
        )
        let systems = generator.systems(projects: try fixtureProjects())
        guard let acme = systems.first(where: { $0.slug == "acme" }) else {
            return XCTFail("no acme system generated")
        }
        let components = acme.sections[.components] ?? ""
        XCTAssertTrue(components.contains("padding 9px 18px"), "the tight default button scale")
        XCTAssertTrue(components.contains("999px pill"), "the pill radius rule")

        let voice = acme.sections[.voice] ?? ""
        XCTAssertTrue(voice.contains("Never use an em dash"), "the no-dash copy law")
        XCTAssertTrue(voice.contains("support@example.com"), "the supplied support contact")

        // The injected palette survives into the derived tokens.
        XCTAssertFalse(acme.paletteHex.isEmpty, "an injected palette reaches the hex tokens")
    }

    func test_unstyledBrandGetsGenericButLawfulSystem() throws {
        let generator = BrandSystemGenerator()
        let systems = generator.systems(projects: try fixtureProjects())
        guard let reg = systems.first(where: { $0.slug == "some-registry" }) else {
            return XCTFail("no registry system generated")
        }
        XCTAssertEqual(reg.name, "Some Registry Brand")
        // With no support contact configured, the system says so rather than
        // naming somebody's address.
        let voice = reg.sections[.voice] ?? ""
        XCTAssertTrue(voice.contains("Never invent a support address"))
        XCTAssertFalse(voice.contains("@"), "an unconfigured brand must not carry any email address")
        XCTAssertTrue((reg.sections[.components] ?? "").contains("padding 9px 18px"))
    }

    func test_slugHygiene_messyNamesProduceCleanSlugs() throws {
        let generator = BrandSystemGenerator()
        let systems = generator.systems(projects: try fixtureProjects())
        XCTAssertTrue(systems.contains { $0.slug == "weird-brand-2" },
                      "'Weird Brand 2' slugs to weird-brand-2, no spaces or capitals")
        for system in systems {
            XCTAssertEqual(system.slug, DesignSystem.slugify(system.slug),
                           "every slug is already fully slugified")
        }
    }

    func test_noEmOrEnDashesInAnyGeneratedDesignMd() throws {
        let generator = BrandSystemGenerator()
        let systems = generator.systems(projects: try fixtureProjects())
        for system in systems {
            let md = system.render()
            XCTAssertFalse(md.contains("\u{2014}"), "\(system.slug) DESIGN.md contains an em dash")
            XCTAssertFalse(md.contains("\u{2013}"), "\(system.slug) DESIGN.md contains an en dash")
        }
    }
}
