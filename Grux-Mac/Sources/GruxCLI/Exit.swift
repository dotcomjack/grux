import ArgumentParser
import Foundation
import GruxSetupCore

/// End the process with one of the four documented codes.
///
/// `Exit` itself lives in GruxSetupCore, because the codes are the contract
/// `docs/cli-grammar.md` publishes and anything that DECIDES one is product logic a test has
/// to be able to reach. Only this line, which cannot be tested because it does not return,
/// belongs to the binary.
func leave(_ code: Exit) -> Never { exit(code.rawValue) }
