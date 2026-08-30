// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Grux",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GruxShellCore", targets: ["GruxShellCore"]),
        .library(name: "GruxAgentCore", targets: ["GruxAgentCore"]),
        .library(name: "GruxMCPCore", targets: ["GruxMCPCore"]),
        .library(name: "GruxSetupCore", targets: ["GruxSetupCore"]),
        // NAMED grux-cli, NOT grux, and this is not a preference.
        //
        // The app's executable target is `Grux`. APFS is case-insensitive by default, so a
        // product named `grux` writes to the SAME PATH as the app binary: measured, same
        // inode, and whichever target built last won. Running `.build/debug/grux status`
        // launched the entire Grux app, started every scheduler, and aborted with
        // `bundleProxyForCurrentProcess is nil`. Nothing failed at build time.
        //
        // The product name only decides the build artifact path. The command a person types
        // is still `grux`, because build.sh installs this binary into the bundle under that
        // name. PackageLayoutTests fails on any future case-insensitive collision.
        .executable(name: "grux-cli", targets: ["GruxCLI"]),
        .executable(name: "ShellDemo", targets: ["ShellDemo"]),
        .executable(name: "IOSDemo", targets: ["IOSDemo"]),
        .executable(name: "SwarmDemo", targets: ["SwarmDemo"]),
        .executable(name: "GruxMCPServer", targets: ["GruxMCPServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        // Already resolved at 1.7.1 as a transitive dependency of WhisperKit. Named here
        // because the CLI links it DIRECTLY, and a direct use riding on somebody else's
        // transitive pin breaks silently the day that dependency drops it.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Platform-free shell-session core: PTY-backed bash process, shadow-git
        // snapshot store, cwd + network safety gates, Terminal.app mirror,
        // session manager, and the JSON dispatcher. No AppKit / SwiftUI. Exists
        // as a library so the Grux app AND the ShellDemo executable can both
        // use it without pulling in the UI stack.
        // The MCP wire format, shared by the two servers that speak it.
        //
        // Framing and envelopes only. Dispatch stays in each server because one is a
        // synchronous stdio loop in a short-lived process and the other is main-actor work
        // in the long-lived app, and forcing those through one abstraction would mean a
        // DispatchQueue.main.sync from a socket queue.
        // What the CLI needs and nothing more.
        //
        // Deliberately does NOT carry the capability vocabulary or the feature registry. The
        // app writes setup-status.json with every id, label, remediation and feature state
        // already resolved, so a second copy of a 41 id contract in this target would be a
        // second thing to keep in step. What lives here is the shared document shape, the
        // terminal renderer, and the client for the app's control socket.
        .target(
            name: "GruxSetupCore",
            path: "Sources/GruxSetupCore"
        ),
        // The grux binary. Thin on purpose: argument parsing and frames.
        .executableTarget(
            name: "GruxCLI",
            dependencies: [
                "GruxSetupCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "GruxShellCore",
            ],
            path: "Sources/GruxCLI"
        ),
        .target(
            name: "GruxMCPCore",
            path: "Sources/GruxMCPCore"
        ),
        .target(
            name: "GruxShellCore",
            path: "Sources/GruxShellCore"
        ),
        // Platform-free swarm-of-workers core: AgentJob, SwarmPlan,
        // SwarmWorker (wraps `claude --print` subprocess), SwarmOrchestrator
        // (DAG executor), AgentStore (NDJSON persistence), MegapromptScaffold,
        // StreamJSONParser. Foundation only, no AppKit, no SwiftUI.
        .target(
            name: "GruxAgentCore",
            path: "Sources/GruxAgentCore"
        ),
        // Full Grux macOS app. Depends on the shell core and wraps it in the
        // ClaudeTool bridge that plugs into ChatService.
        .executableTarget(
            name: "Grux",
            dependencies: [
                "GruxShellCore",
                "GruxAgentCore",
                "GruxMCPCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Grux"
        ),
        // End-to-end demo harness. Runs a scripted sequence of shell tool calls
        // against a real project folder (Projecto 2.0) and prints the results.
        // Lets us prove the ShellTool works without running the full Grux UI.
        .executableTarget(
            name: "ShellDemo",
            dependencies: ["GruxShellCore"],
            path: "Sources/ShellDemo"
        ),
        // Standalone read-only MCP server exposing Grux design projects, design
        // systems, skills and brands to external agents (Claude Code, Cursor).
        // Foundation-only; must not import the app target.
        .executableTarget(
            name: "GruxMCPServer",
            dependencies: ["GruxMCPCore"],
            path: "Sources/GruxMCPServer"
        ),
        // iOS scaffold + build + simulator demo. Runs the full pipeline end
        // to end: doctor → scaffold → build (with auto-retry loop on errors)
        // → simulator launch + screenshot. Proves Grux can ship a compilable
        // iPhone app from zero without the full UI.
        .executableTarget(
            name: "IOSDemo",
            dependencies: ["GruxShellCore"],
            path: "Sources/IOSDemo"
        ),
        // End-to-end swarm orchestrator demo. Spawns a real Claude Code worker
        // subprocess against a tiny prompt and proves the full pipeline works
        // (subprocess launch, stream-json parse, step persistence, completion).
        // Used as the e2e verification harness for the agent framework.
        .executableTarget(
            name: "SwarmDemo",
            dependencies: ["GruxAgentCore"],
            path: "Sources/SwarmDemo"
        ),
        // Unit tests, pure, no UI. Covers ClaudeSessionJSONL parser,
        // ClaudeSessionSlotMapper, agent core (StreamJSONParser, SwarmPlan,
        // MegapromptScaffold, AgentStore round-trip), and other pure logic.
        .testTarget(
            name: "GruxTests",
            dependencies: ["Grux", "GruxAgentCore", "GruxShellCore", "GruxMCPCore", "GruxSetupCore"],
            path: "Tests/GruxTests"
        )
    ]
)
