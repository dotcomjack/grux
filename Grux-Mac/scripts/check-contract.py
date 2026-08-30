#!/usr/bin/env python3
"""
Reconcile the blueprint set and the capability system against the shared contract.

Two specifications were written in parallel against one contract, which is fast and is
exactly how drift gets in. This is the mechanism that turns drift into a red build on the
day it happens rather than a discovery six weeks later.

It parses `docs/contract.md` as the single source of truth and fails on:

  1. a blueprint referencing a capability absent from the vocabulary
  2. a blueprint reading a config key absent from the namespace
  3. a vocabulary entry with no remediation string
  4. a capability declared by zero features, which means it is dead vocabulary
  5. a config key owned by more than one domain
  6. a secret-flagged key appearing anywhere it must not (sample config, blueprints, fixtures)
  7. an em dash or en dash anywhere in the docs, which is a house rule
  8. a malformed anyOf group, where `min` cannot be satisfied or is a flat AND

Exit 0 clean, 1 on any finding. No third-party dependencies, so CI needs no install step.

    python3 scripts/check-contract.py            # check
    python3 scripts/check-contract.py --self-test  # prove the checker itself still works
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = ROOT / "docs" / "contract.md"
BLUEPRINTS = ROOT / "docs" / "blueprints"
CAPABILITY_SPEC = ROOT / "docs" / "capability-system.md"
# Orphan detection is only meaningful once something enumerates every feature. Until this
# file exists, the specs cover blueprints and the capability system but not the full
# feature set, so a capability used only by, say, the mail feature looks orphaned when it
# is merely unwritten. Gating on the file means the rule arms itself automatically.
FEATURE_REGISTRY = ROOT / "docs" / "feature-registry.md"

# A capability id: class-prefixed and dotted. Deliberately strict, because a typo that
# still parses is the failure mode this whole script exists to prevent.
CAPABILITY_ID = re.compile(r"\b((?:key|perm|endpoint|step)\.[a-z0-9_]+)\b")
CONFIG_KEY = re.compile(r"\b(grux\.[a-z0-9_]+(?:\.[a-z0-9_]+)*)\b")
DASHES = re.compile("[–—]")
# Contract section 6 writes an anyOf group as `min of {id, id}` inside a registry
# cell. Rule 8 exists because the constraint `1 <= min < count` was added to the
# contract with nothing enforcing it, and an unenforced constraint is a comment.
ANYOF_GROUP = re.compile(r"(\d+)\s+of\s+\{([^}]*)\}")
# Everything after the first of these headings is exempt from the closed-vocabulary rules.
# A section proposing a change or a deletion has to be able to name what it is proposing,
# and the numbered forms are load-bearing: real headings look like "## 9. Contract change
# requests" and "### 7.1 Recommended contract deletions".
EXEMPT_HEADING = re.compile(
    r"^(#+)\s*(?:\d+(?:\.\d+)*[.)]?\s*)?(?:contract change requests|recommended contract deletions)",
    re.IGNORECASE,
)
ANY_HEADING = re.compile(r"^(#+)\s")


@dataclass
class Finding:
    rule: str
    where: str
    detail: str


@dataclass
class Contract:
    capabilities: dict[str, dict] = field(default_factory=dict)
    config_keys: dict[str, dict] = field(default_factory=dict)


def parse_markdown_table_rows(text: str, header_contains: list[str]) -> list[list[str]]:
    """Yield cell lists for every row of every pipe table whose header has these words."""
    rows: list[list[str]] = []
    in_table = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            in_table = False
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        lowered = " ".join(cells).lower()
        if all(h in lowered for h in header_contains):
            in_table = True
            continue
        if in_table:
            # Skip the alignment row that follows every markdown header.
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
    return rows


def load_contract() -> tuple[Contract, list[Finding]]:
    findings: list[Finding] = []
    if not CONTRACT.exists():
        return Contract(), [Finding("contract-missing", str(CONTRACT), "contract.md not found")]
    text = CONTRACT.read_text(encoding="utf-8")
    c = Contract()

    # Capability tables: id, label, remediation.
    for cells in parse_markdown_table_rows(text, ["id", "label", "remediation"]):
        if len(cells) < 3:
            continue
        raw_id = cells[0].strip().strip("`")
        if not CAPABILITY_ID.fullmatch(raw_id):
            continue
        remediation = cells[2].strip()
        c.capabilities[raw_id] = {"label": cells[1].strip(), "remediation": remediation}
        if not remediation:
            findings.append(Finding("no-remediation", raw_id, "capability has an empty remediation string"))
        elif len(remediation) > 140:
            findings.append(
                Finding("remediation-too-long", raw_id, f"{len(remediation)} chars, contract caps it at 140")
            )

    # Namespace table: key, owner, type, secret.
    for cells in parse_markdown_table_rows(text, ["key", "owner", "secret"]):
        if len(cells) < 4:
            continue
        raw_key = cells[0].strip().strip("`")
        if not CONFIG_KEY.fullmatch(raw_key):
            continue
        owner = cells[1].strip()
        secret = "yes" in cells[3].strip().lower()
        if raw_key in c.config_keys and c.config_keys[raw_key]["owner"] != owner:
            findings.append(
                Finding("duplicate-owner", raw_key, f"owned by both {c.config_keys[raw_key]['owner']} and {owner}")
            )
        c.config_keys[raw_key] = {"owner": owner, "secret": secret}

    if not c.capabilities:
        findings.append(Finding("contract-empty", "docs/contract.md", "no capabilities parsed, check the table headers"))
    if not c.config_keys:
        findings.append(Finding("contract-empty", "docs/contract.md", "no config keys parsed, check the table headers"))
    return c, findings


def binding_text(text: str) -> str:
    """Everything in a document that the closed-vocabulary rules apply to.

    An exempt heading exempts ITS OWN SECTION, not the rest of the file. The first
    version split at the first matching heading and treated everything after it as
    exempt, which was fine while the only such heading was the last section in a
    document. It stopped being fine the moment a "Recommended contract deletions"
    subsection appeared at 62% of the way through the feature registry: that one heading
    silently disabled checking for the remaining 431 lines, roughly 37% of the file,
    including a whole later section of resolved requests.

    A section runs until the next heading at the same level or shallower, so a level-3
    exempt subsection ends at the next level-3 or level-2 heading, and binding text
    resumes there.
    """
    lines = text.splitlines()
    kept: list[str] = []
    exempt_at: int | None = None
    for line in lines:
        m = ANY_HEADING.match(line)
        if m:
            level = len(m.group(1))
            if exempt_at is not None and level <= exempt_at:
                exempt_at = None          # the exempt section has ended
            if exempt_at is None and EXEMPT_HEADING.match(line):
                exempt_at = level
        if exempt_at is None:
            kept.append(line)
    return "\n".join(kept)


def style_files() -> list[Path]:
    """The contract corpus: the top-level contract docs plus the blueprints.

    The checker's own source is excluded deliberately: it has to contain a literal em dash
    and en dash in order to detect them.

    SCOPE, and it is deliberately narrow. This used to `rglob("*.md")` the whole of docs/,
    which was correct while docs/ held nothing but the contract corpus. The contract moved
    into the app repository on 2026-08-17 so a stranger's clone could run the suite, and
    docs/ there already held 22 legacy design docs under adr/, specs/, foundry/,
    integration/ and superpowers/. The recursive glob swept those in and produced two
    findings that are not drift: `grux-key.sh` in a prose sentence parsed as the capability
    `key.sh`, and the Keychain service string `com.gruxai.grux.vault` parsed as the config
    key `grux.vault`.

    Narrowing to the corpus restores the exact scope the rules were written against and
    weakens nothing, because those 22 files were never checked in the first place. Widening
    the style rules to cover design docs is a defensible separate change; silently letting
    id-shaped substrings in unrelated prose fail the contract check is not.
    """
    files = sorted((ROOT / "docs").glob("*.md"))
    if BLUEPRINTS.exists():
        files += sorted(BLUEPRINTS.glob("*.md"))
    return files


def declaring_files() -> list[Path]:
    """Only the docs that DECLARE a feature's capabilities.

    This is deliberately narrower than style_files(), and conflating the two was a real
    bug. Style has to cover contract.md; usage must not. The contract's own tables contain
    every capability id by definition, so counting it as a consumer made the contract
    satisfy itself: 28 of 28 capabilities looked used and the orphan rule became incapable
    of firing. It reported clean with seven capabilities genuinely unclaimed.

    reconciliation.md is excluded for the same reason: it names capability ids in prose
    while explaining the rules, which is documentation, not declaration.

    Blueprints count as declarers alongside the registry. A blueprint is a unit that
    requires capabilities in its own right: `pr-digest` needs a GitHub token and a repo
    list, while the generic `schedules` feature that hosts it needs neither. Counting only
    registry features would have reported six live capabilities as orphans purely because
    the thing that needs them is seed content rather than a sidebar tab.

    capability-system.md is excluded: it names ids illustratively while explaining the
    mechanism, which is documentation and not declaration. It is used as a fallback only
    before either the registry or the blueprints exist, so the rule still does something
    early on.
    """
    files: list[Path] = []
    if FEATURE_REGISTRY.exists():
        files.append(FEATURE_REGISTRY)
    if BLUEPRINTS.exists():
        files += sorted(BLUEPRINTS.glob("*.md"))
    if not files and CAPABILITY_SPEC.exists():
        files.append(CAPABILITY_SPEC)
    return files


def scan_file(rel: str, text: str, contract: Contract, declares: bool,
              findings: list[Finding], used_caps: dict[str, set[str]]) -> None:
    """Every per-file rule, in one place so the self-test can drive the real one.

    Extracted 2026-08-10. The self-test used to re-implement rules 1, 2 and 7 inline,
    which meant it proved the regexes matched and nothing else. It could not catch a bug
    in this function, and a rule added here was invisible to it: rule 8 was added, the
    self-test was extended to cover it, and all three of its new cases failed while the
    rule was present and working. A self-test that mirrors the implementation tests the
    mirror.
    """
    
    # Rule 7: house style. Cheap to check, expensive to fix after the fact.
    for n, line in enumerate(text.splitlines(), 1):
        if DASHES.search(line):
            findings.append(Finding("dash", f"{rel}:{n}", line.strip()[:90]))

    # Contract change requests are allowed to name things that do not exist yet, which
    # is the whole point of raising one. Everything before that heading is binding.
    # The heading is commonly numbered ("## 9. Contract change requests"), so the
    # optional number is load-bearing. Without it the exemption never fires and every
    # legitimate change request is reported as drift, which trains people to ignore
    # the checker. That is a worse failure than missing a real finding.
    binding = binding_text(text)

    
    declaration_lines = "\n".join(
        l for l in binding.splitlines() if l.lstrip().startswith("|"))

    for cap in set(CAPABILITY_ID.findall(binding)):
        if cap not in contract.capabilities:
            findings.append(Finding("unknown-capability", rel, cap))
    if declares:
        for cap in set(CAPABILITY_ID.findall(declaration_lines)):
            if cap in contract.capabilities:
                used_caps.setdefault(cap, set()).add(rel)

    # Rule 8. An anyOf group whose min equals its member count is a flat AND wearing
    # a costume, and one that exceeds the count can never be satisfied at all, which
    # would render the feature permanently needs-setup with no action that fixes it.
    for n, line in enumerate(binding.splitlines(), 1):
        for raw_min, members in ANYOF_GROUP.findall(line):
            ids = CAPABILITY_ID.findall(members)
            if not ids:
                continue
            lo = int(raw_min)
            if lo >= len(ids) or lo < 1:
                findings.append(Finding(
                    "malformed-anyof", f"{rel}:{n}",
                    f"{lo} of {len(ids)}, contract section 6 requires 1 <= min < count"))

    for key in set(CONFIG_KEY.findall(binding)):
        if key not in contract.config_keys:
            findings.append(Finding("unknown-config-key", rel, key))
        elif contract.config_keys[key]["secret"]:
            # Rule 6. Naming a secret key is fine; showing it with a value is not.
            for n, line in enumerate(binding.splitlines(), 1):
                if key in line and re.search(re.escape(key) + r"\s*[=:]\s*\S", line):
                    if "none" not in line.lower() and "<" not in line:
                        findings.append(
                            Finding("secret-with-value", f"{rel}:{n}", f"{key} appears with a literal value")
                        )


def check(contract: Contract, findings: list[Finding]) -> list[Finding]:
    used_caps: dict[str, set[str]] = {}
    files = style_files()
    declaring = {p.resolve() for p in declaring_files()}

    if not files:
        findings.append(Finding("no-specs", "docs/", "no blueprints or capability spec found yet"))

    for path in files:
        scan_file(str(path.relative_to(ROOT)), path.read_text(encoding="utf-8"),
                  contract, path.resolve() in declaring, findings, used_caps)

    # Rule 4: vocabulary that nothing uses is vocabulary that will rot. Reported as a
    # warning until the feature registry exists, because before then "declared by zero
    # features" cannot be distinguished from "declared by a feature nobody has specced".
    # Failing on it now would mean a permanently red build that everyone learns to ignore.
    registry_exists = FEATURE_REGISTRY.exists()
    orphans = [cap for cap in contract.capabilities if cap not in used_caps]
    for cap in orphans:
        rule = "orphan-capability" if registry_exists else "orphan-capability-warning"
        findings.append(Finding(rule, "docs/contract.md", f"{cap} is declared by zero features"))

    return findings


def self_test() -> int:
    """Prove the checker fails on things it should. A check that never fails is decoration."""
    import tempfile

    cases = [
        ("unknown capability", "Requires `key.doesnotexist`.", "unknown-capability"),
        ("unknown config key", "Reads `grux.nope.nothing`.", "unknown-config-key"),
        ("em dash", "This line has an em dash — right here.", "dash"),
        ("en dash", "A range 1\u20132 like this.", "dash"),
        # Rule 8. All three shapes are wrong in different ways: min above the count can
        # never be satisfied, min equal to the count is a flat AND that should have said
        # so, and min below one declares nothing.
        ("anyof min above count",
         "A row needing 3 of {`key.anthropic`, `endpoint.ollama`}.", "malformed-anyof"),
        ("anyof min equals count",
         "A row needing 2 of {`key.anthropic`, `endpoint.ollama`}.", "malformed-anyof"),
        ("anyof min below one",
         "A row needing 0 of {`key.anthropic`, `endpoint.ollama`}.", "malformed-anyof"),
    ]
    # Regression: a NUMBERED change-request heading must exempt what follows it. The
    # first version of this splitter only matched an unnumbered heading, so every
    # legitimate request was reported as drift.
    heading_cases = [
        ("## Contract change requests", True),
        ("## 9. Contract change requests", True),
        ("### 12) Contract change requests", True),
        ("## Something else", False),
        ("### 7.1 Recommended contract deletions", True),
    ]
    # Regression: an exempt heading exempts ITS SECTION, not the rest of the file. A
    # "Recommended contract deletions" subsection two thirds of the way through the
    # feature registry silently disabled checking for the remaining 431 lines.
    scoped = (
        "## 7. Orphans\n"
        "### 7.1 Recommended contract deletions\n"
        "Deleting `key.exempt_here`.\n"
        "## 8. Registry\n"
        "A row requiring `key.binding_again`.\n"
    )
    # Initialised here and never re-initialised. It used to be assigned only after the
    # first two loops had already tried to increment it, so a failure in either raised
    # UnboundLocalError instead of printing FAIL, and took every later case with it.
    failures = 0
    # Regression: a declaration is a table ROW. A prose mention in a declaring file used to
    # count as usage, which is CR-9's defect one level down and left the orphan rule blind.
    usage_cases = [
        ("| `home` | Home | core | `key.anthropic` | none | none | none |", True),
        ("The `key.anthropic` capability is discussed here in prose.", False),
    ]
    for body, want_used in usage_cases:
        contract, _ = load_contract()
        caps: dict[str, set[str]] = {}
        scan_file("probe.md", body, contract, True, [], caps)
        got = "key.anthropic" in caps
        ok = got == want_used
        shape = "table row" if want_used else "prose only"
        print(f"  {'ok  ' if ok else 'FAIL'} usage from {shape}: counted={got}, want={want_used}")
        if not ok:
            failures += 1
    scoped_cases = [("key.exempt_here", False), ("key.binding_again", True)]
    sb = binding_text(scoped)
    for token, want_present in scoped_cases:
        got = token in sb
        ok = got == want_present
        print(f"  {'ok  ' if ok else 'FAIL'} section-scoped exemption, {token} binding={got}, want={want_present}")
        if not ok:
            failures += 1
    for heading, should_exempt in heading_cases:
        doc = f"binding text\n{heading}\nRequires `key.doesnotexist`."
        binding = binding_text(doc)
        exempted = "key.doesnotexist" not in binding
        ok = exempted == should_exempt
        print(f"  {'ok  ' if ok else 'FAIL'} heading exemption {heading!r}: exempt={exempted}, want={should_exempt}")
        if not ok:
            failures += 1
    total = len(cases) + len(heading_cases) + len(scoped_cases) + len(usage_cases)
    for name, body, expected_rule in cases:
        contract, _ = load_contract()
        local: list[Finding] = []
        # The real scanner, not a re-implementation of it. `declares` is True so the
        # usage-counting branch is exercised too.
        scan_file("probe.md", body, contract, True, local, {})
        got = {f.rule for f in local}
        ok = expected_rule in got
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: expected {expected_rule}, got {sorted(got) or 'nothing'}")
        if not ok:
            failures += 1
    print(f"\nself-test: {total - failures} of {total} passed")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    contract, findings = load_contract()
    findings = check(contract, findings)

    print(f"contract: {len(contract.capabilities)} capabilities, {len(contract.config_keys)} config keys")
    print(f"specs:    {len(style_files())} files")
    src = "feature registry" if FEATURE_REGISTRY.exists() else "blueprints and capability spec"
    print(f"usage:    counted from the {src}, orphan rule {'ARMED' if FEATURE_REGISTRY.exists() else 'warning only'}")

    errors = [f for f in findings if not f.rule.endswith("-warning")]
    warnings = [f for f in findings if f.rule.endswith("-warning")]

    if warnings:
        print(f"\n{len(warnings)} warnings (not failing):\n")
        for f in warnings[:12]:
            print(f"      {f.where}: {f.detail}")
        if len(warnings) > 12:
            print(f"      ... and {len(warnings) - 12} more")
        if not FEATURE_REGISTRY.exists():
            print("\n  orphan checks stay warnings until docs/feature-registry.md exists.")

    if not errors:
        print("\nclean, no drift")
        return 0
    findings = errors

    by_rule: dict[str, list[Finding]] = {}
    for f in findings:
        by_rule.setdefault(f.rule, []).append(f)

    print(f"\n{len(findings)} findings:\n")
    for rule, items in sorted(by_rule.items()):
        print(f"  [{rule}] {len(items)}")
        for f in items[:12]:
            print(f"      {f.where}: {f.detail}")
        if len(items) > 12:
            print(f"      ... and {len(items) - 12} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())
