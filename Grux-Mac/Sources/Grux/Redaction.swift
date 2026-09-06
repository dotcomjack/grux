import Foundation
import GruxGuardrails

/// The redactor is `grux-guardrails`, not this file.
///
/// ## What used to be here, and why it is gone
///
/// A 129 line `SecretRedactor` that this app carried while the extracted, hardened
/// version of the same code sat in its own repository being fixed. The two diverged for
/// three weeks and nobody noticed, because nothing connected them: no dependency, no
/// shared test, no guard. The package reached 1608 lines and 119 tests across six rounds
/// of adversarial review; the copy here stayed at its first draft.
///
/// Probed 2026-09-06 against this app's own shipping code, six of the eight defects
/// disclosed in the advisories for 0.1.0 through 0.4.0 were live in it, including both
/// criticals:
///
///   - The PEM pattern matched only the `-----BEGIN ...-----` line, so the key BODY was
///     stamped `[REDACTED:PEM]` and then passed to the model underneath the marker. The
///     transcript looked redacted, which is what made it dangerous.
///   - `wrapAsUntrusted` closed its fence with a fixed literal, so any untrusted text
///     containing `</untrusted_data>` escaped the block and everything after it read as
///     operator instructions. One line, written by an attacker, in an email. This app
///     reads your screen and your mail, so that is the input class it exists for.
///   - A 40 character AWS secret with only three character classes, a labelled secret
///     under the 40 character entropy floor (`DB_PASS=`, `HF_TOKEN=`), and the PEM tail
///     all survived redaction.
///
/// ## Why an alias rather than a copy
///
/// Copying is what produced the divergence. An alias cannot drift: there is one
/// implementation, it has a version, and Dependabot tells you when an advisory lands
/// against it. That last part matters more than it sounds, because the six advisories
/// this package carries are the mechanism by which a consumer finds out their redactor
/// is broken.
///
/// The call sites did not change. `SecretRedactor.redact` and
/// `SecretRedactor.wrapAsUntrusted` have identical signatures in the package, which is
/// unsurprising: the package was extracted from this file.
typealias SecretRedactor = GruxGuardrails.SecretRedactor
