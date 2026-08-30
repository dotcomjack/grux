import Foundation

// grux-mcp: a standalone stdio MCP server that exposes Grux's design projects,
// design systems, learned skills, and brands to external agents (Claude Code
// and any MCP client) over newline-delimited JSON-RPC on stdin/stdout.
//
// Everything is READ-ONLY: the server reads the same on-disk stores the Grux
// app writes (~/Documents/Grux and ~/Library/Application Support/Grux) and
// never modifies them. It runs until the client closes stdin (EOF), then exits
// cleanly.
//
// Register it with Claude Code once built (see INTEGRATION.md):
//   claude mcp add grux -- /path/to/grux-mcp

let server = MCPServerCore(
    readHandle: .standardInput,
    writeHandle: .standardOutput,
    roots: .live()
)
server.run()
