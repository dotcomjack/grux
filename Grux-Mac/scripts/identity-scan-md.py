#!/usr/bin/env python3
"""
The markdown half of NoPersonalIdentityTests, with no Swift toolchain.

The Swift guard scans every `.md` file in the shipping tree, but it only runs in
the macOS job, and ci.yml skips that job on documentation-only commits. So the
one file type this guard reads whole was the one file type that could reach
`main` unchecked. Measured 2026-10-23: the commit that announced Grux Local
changed README.md and nothing else, the macOS job did not run, and five identity
hits reached `main` with no identity verdict.
This runs the same markdown scan in the Linux job, which has no path filter.

It READS the Swift guard's inputs and copies none of them:

  - the vocabulary:         Tests/GruxTests/banned-vocabulary.json
  - knownRemaining and
    allowedExactTokens:     parsed out of Tests/GruxTests/NoPersonalIdentityTests.swift
  - the exclusions:         scripts/oss-exclude.txt

so a term, an exemption or an exclusion added for the Swift guard applies here the
same day. Two copies of one list have drifted in this repo before; that is the
bug this layout exists to rule out.

What it does NOT cover: banned words inside `.swift` string literals. That is the
Swift test's other half and still runs only on macOS.

The matching logic is a port, not shared code: a change to how the Swift scan
matches needs the same change here. Every rule below cites the Swift it mirrors,
by function name and by line in NoPersonalIdentityTests.swift as of origin/main
bf90d694. The names are the stable reference; the line numbers move when the
file is edited. Where this deliberately differs, it differs toward failing.

This file ships, and the pre-publish byte scan reads every shipped file against
the same vocabulary, so it names no banned term anywhere, comments included. The
self-test takes every word it plants from the vocabulary at run time.

Exit 0 clean, 1 on any hit or stale exemption, 2 when an input cannot be read
or an argument is not recognised.
No third-party dependencies, so CI needs no install step.

    python3 scripts/identity-scan-md.py              # scan the repository
    python3 scripts/identity-scan-md.py --self-test  # prove the scan can fail
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from dataclasses import dataclass, replace
from pathlib import Path

# repoRoot(), L517-522: the Swift PACKAGE root, Grux-Mac. The scan root is its
# parent, scanShippingTree(), L203-206.
PACKAGE = Path(__file__).resolve().parent.parent
REPO = PACKAGE.parent
SWIFT_TEST = PACKAGE / "Tests" / "GruxTests" / "NoPersonalIdentityTests.swift"
VOCABULARY = PACKAGE / "Tests" / "GruxTests" / "banned-vocabulary.json"
# manifestURL(), L166-168.
MANIFEST = PACKAGE / "scripts" / "oss-exclude.txt"
# The reach floor run() enforces on the real tree.
REQUIRED_READS = ("README.md", "GOVERNANCE.md", "Grux-Mac/CLAUDE.md")
MIN_FILES = 50

# CharacterSet.whitespaces, which the Swift trims with (L189, L567, L570): Unicode
# category Zs plus the tab. NOT newlines, so this is not str.strip().
SWIFT_WHITESPACE = "\t" + "".join(
    chr(c) for c in range(0x10000) if unicodedata.category(chr(c)) == "Zs")

# One Swift string literal in a list: "...", then a comma or the end.
STRING_ITEM = re.compile(r'\s*"([^"\\]*)"\s*(?:,|$)')
# One knownRemaining entry, the shape every entry has: "path": ["term", ...],
KNOWN_ENTRY = re.compile(r'"([^"\\]+)":\s*\[(.*)\],?')
EXACT_TOKENS = re.compile(
    r"^\s*static let allowedExactTokens: Set<String> = \[(.*)\]\s*$", re.MULTILINE)


class InputError(Exception):
    """An input the scan depends on is missing or unreadable. Exit 2, never a pass."""


@dataclass(frozen=True)
class Hit:
    # struct Hit, L136-145.
    file: str
    line: int
    text: str
    word: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line} [{self.word}] {self.text}"


@dataclass(frozen=True)
class Inputs:
    banned: list[str]
    allowed_contexts: list[str]
    exact_tokens: set[str]
    known_remaining: dict[str, set[str]]
    excluded: list[str]


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

def load_vocabulary() -> tuple[list[str], list[str]]:
    # The vocabulary loader, L74-90: missing, unreadable or empty traps instead of
    # defaulting to empty, because an empty list reports every tree as clean.
    try:
        data = json.loads(VOCABULARY.read_bytes().decode("utf-8"))
        banned, allowed = data["banned"], data["allowed_contexts"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise InputError(f"{VOCABULARY}: {e}") from e
    for name, value in (("banned", banned), ("allowed_contexts", allowed)):
        if not isinstance(value, list) or not value or not all(isinstance(v, str) for v in value):
            raise InputError(f"{VOCABULARY}: `{name}` must be a non-empty list of strings")
    if not all(c.strip() for c in allowed):
        # An empty context is a substring of every line, so it would skip every
        # line in the tree, and a blank one skips nearly every line. Refused here
        # rather than mirrored.
        raise InputError(f"{VOCABULARY}: `allowed_contexts` holds an empty or blank "
                         "string, which would skip every line")
    return banned, allowed


def string_list(body: str, where: str) -> list[str]:
    """The items of a one-line Swift list of plain string literals, or InputError."""
    out, pos, body = [], 0, body.strip()
    while pos < len(body):
        m = STRING_ITEM.match(body, pos)
        if not m:
            raise InputError(f"{where}: cannot read {body!r} as a list of string literals")
        out.append(m.group(1))
        pos = m.end()
    return out


def parse_swift_test(path: Path = SWIFT_TEST) -> tuple[set[str], dict[str, set[str]]]:
    try:
        src = path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise InputError(f"{path}: {e}") from e

    # allowedExactTokens, L132: a one-line Set literal.
    m = EXACT_TOKENS.search(src)
    if not m:
        raise InputError(f"{path}: no one-line `static let allowedExactTokens` declaration")
    tokens = set(string_list(m.group(1), "allowedExactTokens"))

    # knownRemaining, L287-360: from its declaration to the line that is only `]`.
    # Every line in between is blank, a `//` comment, or one whole entry. Anything
    # else stops the run, because an entry this cannot read would be an exemption
    # the Swift guard grants and this one silently refuses, or the reverse.
    lines = src.split("\n")
    start = next((i for i, l in enumerate(lines) if "static let knownRemaining" in l), None)
    if start is None:
        raise InputError(f"{path}: no `static let knownRemaining` declaration")
    if lines[start].rstrip().endswith("[:]"):
        # The goal state the Swift comment names, written as an empty literal.
        # Unambiguous, so it is an answer and not a failed parse.
        return tokens, {}
    known: dict[str, set[str]] = {}
    for n, line in enumerate(lines[start + 1:], start + 2):
        s = line.strip()
        if s == "]":
            break
        if not s or s.startswith("//"):
            continue
        m = KNOWN_ENTRY.fullmatch(s)
        if not m:
            raise InputError(f"{path}:{n}: not a one-line `\"path\": [\"term\"],` "
                             f"knownRemaining entry: {s}")
        known[m.group(1)] = set(string_list(m.group(2), f"{path}:{n}"))
    else:
        raise InputError(f"{path}: knownRemaining never closes")
    if not known:
        raise InputError(f"{path}: knownRemaining parsed to zero entries, which is a "
                         "parse failure unless the literal is written `[:]`")
    return tokens, known


def excluded_prefixes() -> list[str]:
    # excludedPrefixes(), L174-193. ABSENT is the published tree, where every file
    # present shipped, so no exclusions is the correct answer there and can only
    # widen the scan (L177-182). oss-exclude.txt lists itself, so in that tree it
    # really is absent. Present but unreadable is an input failure.
    if not MANIFEST.exists():
        return []
    try:
        text = MANIFEST.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise InputError(f"{MANIFEST}: {e}") from e
    out = []
    for raw in text.split("\n"):
        line = raw.split("#", 1)[0].strip(SWIFT_WHITESPACE)
        if line:
            out.append(line)
    return out


def load_inputs() -> Inputs:
    banned, allowed = load_vocabulary()
    tokens, known = parse_swift_test()
    return Inputs(banned, allowed, tokens, known, excluded_prefixes())


# ---------------------------------------------------------------------------
# The scan
# ---------------------------------------------------------------------------

def _skipped_by_name(rel: str) -> bool:
    # isSkipped(_:_:), L196-198. CONTAINS, not prefix, for all but the first.
    if rel.startswith(".git/") or "/.git/" in rel:
        return True
    if ".build/" in rel or "DerivedData/" in rel:
        return True
    return ".swiftpm/" in rel or "__pycache__/" in rel


def is_skipped(rel: str, excluded: list[str]) -> bool:
    # isSkipped(_:_:), L195-200, predicate for predicate.
    return _skipped_by_name(rel) or any(rel == p or rel.startswith(p + "/") for p in excluded)


def markdown_files(root: Path, excluded: list[str]):
    # scan(root:skipping:), L536-540: every path the enumerator yields, hidden ones
    # included (it reaches .github/), whose extension is exactly "md".
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir.replace(os.sep, "/") + "/"
        # Prune a directory only where the skip is inherited by every path under
        # it, so pruning changes the time this takes and never the verdict.
        dirnames[:] = sorted(
            d for d in dirnames
            if not (_skipped_by_name(rel_dir + d + "/")
                    or any(rel_dir + d == p or (rel_dir + d).startswith(p + "/")
                           for p in excluded)))
        for name in sorted(filenames):
            rel = rel_dir + name
            if os.path.splitext(name)[1] == ".md" and not is_skipped(rel, excluded):
                yield rel


def split_lines(src: str) -> list[str]:
    # src.split(separator: "\n", omittingEmptySubsequences: false), L545. A Swift
    # Character holds "\r\n" as ONE character, which never equals "\n", so the
    # Swift scan reads a CRLF file as one long line. Mirrored rather than
    # corrected, so the two guards cannot disagree; measured 2026-10-23, no
    # tracked .md file uses CRLF.
    return re.split(r"(?<!\r)\n", src)


def contains_word(hay: str, needle: str) -> bool:
    # containsWord(_:_:), L586-598: the needle must not touch a letter on either
    # side, and after a rejected match the search resumes at that match's END.
    # Swift asks Character.isLetter of the neighbouring grapheme, this asks
    # str.isalpha() of the neighbouring code point: the same answer on ASCII and
    # on precomposed text. Digits and `_` are not letters on either side.
    if not needle:
        return False  # Foundation's range(of: "") finds nothing.
    start = 0
    while True:
        i = hay.find(needle, start)
        if i < 0:
            return False
        j = i + len(needle)
        before_ok = i == 0 or not hay[i - 1].isalpha()
        after_ok = j == len(hay) or not hay[j].isalpha()
        if before_ok and after_ok:
            return True
        if j >= len(hay):
            return False
        start = j


def scan(root: Path, inputs: Inputs, excluded: list[str]) -> tuple[list[Hit], list[str]]:
    """Every hit under root, and every markdown file read."""
    hits: list[Hit] = []
    read: list[str] = []
    allowed = [c.lower() for c in inputs.allowed_contexts]
    for rel in markdown_files(root, excluded):
        try:
            # Bytes, not text mode: text mode would fold "\r\n" before split_lines.
            src = (root / rel).read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as e:
            # DIVERGES from L542 on purpose, toward failing: the Swift scan skips a
            # file it cannot read as UTF-8 and reports nothing, so that file was
            # never checked. Refusing to pass is the safe direction.
            raise InputError(f"{rel} is not readable as UTF-8: {e}") from e
        read.append(rel)
        for n, line in enumerate(split_lines(src), 1):
            # L550: in markdown the WHOLE LINE is the one span.
            hay = line.lower()
            # L565: lowercase BOTH sides. One allowed context anywhere on the line
            # skips the line for every banned word.
            if any(c in hay for c in allowed):
                continue
            # L566-567: only a line that IS the bare token, once trimmed.
            if hay.strip(SWIFT_WHITESPACE) in inputs.exact_tokens:
                continue
            # L568: the FIRST banned word in vocabulary order, one hit per line.
            word = next((w for w in inputs.banned if contains_word(hay, w)), None)
            if word is not None:
                hits.append(Hit(rel, n, line.strip(SWIFT_WHITESPACE), word))
    return hits, read


def verdict(hits: list[Hit], inputs: Inputs) -> tuple[list[Hit], list[tuple[str, str]]]:
    # testNoPersonalIdentityInShippedStrings, L221-227: a hit is forgiven only for
    # the exact (file, word) pair knownRemaining names. vocabularyFiles (L114-121)
    # is not consulted: every entry in it is a .swift file, which this scan never
    # opens, so it can forgive nothing here.
    unexpected = [h for h in hits if h.word not in inputs.known_remaining.get(h.file, ())]
    # testKnownRemainingIsNotStale, L365-374: checked against EVERY hit, before
    # exemption. Only .md entries, since a .swift entry is the Swift half's to judge.
    stale = [(path, word)
             for path, words in sorted(inputs.known_remaining.items()) if path.endswith(".md")
             for word in sorted(words)
             if not any(h.file == path and h.word == word for h in hits)]
    return unexpected, stale


def run(root: Path = REPO, inputs: Inputs | None = None) -> int:
    inputs = inputs or load_inputs()
    hits, read = scan(root, inputs, inputs.excluded)
    # The reach floor, the markdown half of testTheScanReachesTheWholeShippingTree
    # (L237-253): a walk cut short reports a clean tree. 75 files on 2026-10-23,
    # and the three named files ship in every tree, private and published.
    missing = [p for p in REQUIRED_READS if p not in read]
    if missing or len(read) < MIN_FILES:
        raise InputError(f"the scan read {len(read)} markdown files under {root} "
                         f"(floor {MIN_FILES}), missing {missing}, so a clean result means nothing")
    unexpected, stale = verdict(hits, inputs)
    for h in unexpected:
        print(h)
    for path, word in stale:
        print(f"{path} [{word}] is exempted in knownRemaining but no longer matches. "
              "Remove that term from knownRemaining.")
    print(f"identity scan: {len(read)} markdown files, {len(unexpected)} hits, "
          f"{len(stale)} stale exemptions")
    return 1 if unexpected or stale else 0


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def self_test() -> int:
    """Prove the scan can fail. Independent of whether the tree is clean today."""
    inputs = load_inputs()
    failures: list[str] = []

    def check(ok: bool, what: str) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {what}")
        if not ok:
            failures.append(what)

    plant = next((w for w in inputs.banned if w not in inputs.exact_tokens), None)
    if plant is None:
        raise InputError("every banned word is an allowed exact token, so there is nothing to plant")
    token = min(inputs.exact_tokens) if inputs.exact_tokens else None

    # 1. Word boundaries, for every banned word (testWordBoundaryMatching, L499-505).
    # Failures are reported by vocabulary index, so the log names no term.
    missed = [i for i, w in enumerate(inputs.banned)
              if not (contains_word(f"good morning, {w}", w) and contains_word(f"{w}'s notes", w))]
    invented = [i for i, w in enumerate(inputs.banned)
                if contains_word(f"tried to hi{w} me", w) or contains_word(f"{w}al", w)]
    check(not missed, f"every banned word matches on word boundaries (missed: {missed})")
    check(not invented, f"no banned word matches inside a longer word (matched: {invented})")

    # 2. The markdown lens alone, in a temp dir with no exclusions
    #    (testTheScannerReadsMarkdownProse, L402-419; testTheScannerDoesNotInventMatches, L480-496).
    lines = ["# Blueprint", "",
             f"The engine posts a snapshot for {plant}, with no quotes anywhere.",
             f"An allowed context forgives the line: {inputs.allowed_contexts[0]} {plant}."]
    expected = {3: plant}
    if token is not None:
        lines += [f"Something on your screen tried to hi{token} me.",
                  f"  {token.upper()}  ",
                  f"Good morning, {token}"]
        greeting = next((w for w in inputs.banned if contains_word(f"good morning, {token}", w)), None)
        if greeting is not None:
            expected[len(lines)] = greeting
    with tempfile.TemporaryDirectory(prefix="grux-identity-md-") as tmp:
        Path(tmp, "Blueprint.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
        hits, _ = scan(Path(tmp), inputs, [])
    got = {h.line: h.word for h in hits}
    check(got.get(3) == plant, "a banned word in plain prose is reported")
    check(4 not in got, "an allowed context on the line suppresses the hit")
    if token is not None:
        check(5 not in got, "the hi- prefix of the exact token is not a match")
        check(6 not in got, "a line that is only the exact token, any case, is not reported")
        check(got == expected, "a sentence containing the exact token IS still reported, "
                               "and nothing else on the page is")

    # 3. The verdict alone, on hits built by hand: forgiveness is per (file, word),
    #    never per file (L221-227), and an exemption with no hit is stale (L365-374).
    w1, w2 = inputs.banned[0], inputs.banned[1]
    known = {"listed.md": {w1}, "quiet.md": {w1}, "Quiet.swift": {w1}}
    listed_pair = Hit("listed.md", 1, "", w1)
    unlisted_word = Hit("listed.md", 2, "", w2)
    unlisted_file = Hit("other.md", 3, "", w1)
    unexpected, stale = verdict([listed_pair, unlisted_word, unlisted_file],
                                replace(inputs, known_remaining=known))
    check(unlisted_word in unexpected, "a hit on an unlisted word in a listed file is unexpected")
    check(unlisted_file in unexpected, "a listed word in an unlisted file is unexpected")
    check(listed_pair not in unexpected, "a listed (file, word) pair is forgiven")
    check(stale == [("quiet.md", w1)], "a listed .md term with no hit is stale, "
                                       "and a .swift entry is left to the Swift half")

    # 4. run() end to end on a temp tree that clears the reach floor and holds no
    #    hits, so a stale exemption is the ONLY thing that can fail it. The control
    #    plants the exempted word, so the same inputs then exit 0.
    stale_only = replace(inputs, known_remaining={"README.md": {plant}}, excluded=[])
    codes = []
    for readme in ("# Clean\n", f"Made by {plant}.\n"):
        with tempfile.TemporaryDirectory(prefix="grux-identity-run-") as tmp:
            for rel in REQUIRED_READS + tuple(f"docs/f{i}.md" for i in range(MIN_FILES)):
                Path(tmp, rel).parent.mkdir(parents=True, exist_ok=True)
                Path(tmp, rel).write_text("# Clean\n", encoding="utf-8")
            Path(tmp, "README.md").write_text(readme, encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                codes.append(run(Path(tmp), stale_only))
    check(codes == [1, 0], f"a stale exemption alone exits 1, and its control exits 0 (got {codes})")

    # 5. The knownRemaining parse, on a stub with one multi-term entry, one
    #    single-term entry and a comment between them.
    with tempfile.TemporaryDirectory(prefix="grux-identity-parse-") as tmp:
        stub = Path(tmp, "Stub.swift")
        stub.write_text("\n".join([
            f'    static let allowedExactTokens: Set<String> = ["{w1}"]',
            "    static let knownRemaining: [String: Set<String>] = [",
            f'        "a/One.md": ["{w1}", "{w2}"],',
            "        // a comment the parse skips",
            f'        "Two.md": ["{w2}"],',
            "    ]"]) + "\n", encoding="utf-8")
        parsed = parse_swift_test(stub)
    check(parsed == ({w1}, {"a/One.md": {w1, w2}, "Two.md": {w2}}),
          "the parse yields the exact tokens and every entry's exact terms")

    # 6. The real tree, end to end through the CLI and its exit code
    #    (testTheScanCoversFilesOutsideTheOldThreeRoots, L433-449; and
    #    testTheScanStillSkipsWhatDoesNotShip, L454-475, when there is a manifest).
    #    Asserted on the PLANT'S OWN line, because a tree that is already red
    #    exits 1 whether or not the plant was seen.
    if not (PACKAGE / "docs").is_dir():
        raise InputError(f"{PACKAGE / 'docs'} is missing, so there is nowhere to plant")
    stamp = uuid.uuid4().hex
    inside = f"Grux-Mac/docs/plant-{stamp}.md"
    excluded_dir = next((p for p in inputs.excluded if (REPO / p).is_dir()), None)
    outside = f"{excluded_dir}/plant-{stamp}.md" if excluded_dir else None
    planted = [p for p in (inside, outside) if p]
    try:
        for rel in planted:
            (REPO / rel).write_text(
                f"A blueprint that mentions {plant} in prose, with no quotes anywhere.\n",
                encoding="utf-8")
        r = subprocess.run([sys.executable, str(Path(__file__).resolve())],
                           capture_output=True, text=True)
    finally:
        for rel in planted:
            (REPO / rel).unlink(missing_ok=True)
    check(r.returncode == 1, f"the scan exits 1 with a plant in the tree (got {r.returncode})")
    check(f"{inside}:1 [{plant}]" in r.stdout, f"the scan reports the plant at {inside}")
    if outside:
        check(outside not in r.stdout, f"a plant under the excluded {excluded_dir}/ is not reported")
    else:
        print("skip no manifest or no excluded directory present, so no exclusion to prove")

    print(f"self-test: {len(failures)} failures")
    return 1 if failures else 0


def main() -> int:
    args = sys.argv[1:]
    if args not in ([], ["--self-test"]):
        # A typo such as --selftest must not quietly run the plain scan instead.
        print(f"identity-scan-md: unknown arguments {args}; "
              "usage: identity-scan-md.py [--self-test]", file=sys.stderr)
        return 2
    try:
        return self_test() if args else run()
    except InputError as e:
        print(f"identity-scan-md: cannot read its inputs: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
