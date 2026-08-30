#!/usr/bin/env python3
"""Build THIRD-PARTY-NOTICES.md from Package.resolved, and refuse to guess.

Grux is MIT. MIT's single obligation is that the copyright notice and permission
notice travel with the software, and six of the eight things Grux links are
Apache 2.0, which asks for more: retain the notices, include the licence, and
where the work ships a NOTICE file, reproduce its contents (section 4d).

Measured 2026-08-23, before this script existed: the repo carried no notices, the
app bundle carried none either, and gruxai.com told visitors the licence text was
in the app bundle. Three separate ways of saying nothing was there.

WHY A GENERATOR RATHER THAN A FILE SOMEBODY MAINTAINS. A hand-written notices
file is correct on the day it is written and silently wrong the first time
somebody adds a dependency, which is the same shape as every other defect this
codebase has been fixing: nothing crashes, nothing fails, the wrong answer looks
exactly like the right one. This reads the resolved graph, reads each checkout's
own LICENSE and NOTICE bytes, and writes the file. `--check` re-runs it and
fails if the committed copy has drifted, which is what the test calls.

    python3 scripts/gen-third-party-notices.py            # write it
    python3 scripts/gen-third-party-notices.py --check     # fail if stale
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAC_ROOT = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(MAC_ROOT)
RESOLVED = os.path.join(MAC_ROOT, "Package.resolved")
CHECKOUTS = os.path.join(MAC_ROOT, ".build", "checkouts")
OUT = os.path.join(REPO_ROOT, "THIRD-PARTY-NOTICES.md")

HEADER = """# Third party notices

Grux is MIT licensed. It also links the software below, and each of those
licences asks to travel with it.

This file is GENERATED from `Grux-Mac/Package.resolved` and from each
dependency's own `LICENSE` and `NOTICE` bytes, by
`Grux-Mac/scripts/gen-third-party-notices.py`. Do not edit it by hand: add a
dependency and the generator picks it up, and `ThirdPartyNoticesTests` fails if
this file has drifted from what actually ships.

Six of these are Apache 2.0, whose section 4(d) requires the contents of any
`NOTICE` file be reproduced in redistributions. Where a dependency ships one, it
is included verbatim below.

"""


def read_first(directory, *names):
    """First readable file matching any of the given prefixes, or None."""
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        return None, None
    for prefix in names:
        for e in entries:
            if e.upper().startswith(prefix):
                p = os.path.join(directory, e)
                if os.path.isfile(p):
                    try:
                        with open(p, encoding="utf-8", errors="replace") as fh:
                            return e, fh.read().strip()
                    except OSError:
                        pass
    return None, None


def licence_kind(text):
    if not text:
        return "unknown"
    head = text[:4000]
    for pat, name in (
        (r"Apache License\s*\n?\s*Version 2\.0", "Apache 2.0"),
        (r"\bMIT License\b", "MIT"),
        (r"Permission is hereby granted, free of charge", "MIT"),
        (r"BSD 3-Clause", "BSD 3-Clause"),
        (r"BSD 2-Clause", "BSD 2-Clause"),
        (r"Mozilla Public License", "MPL 2.0"),
    ):
        if re.search(pat, head):
            return name
    return "see text below"


def pins():
    with open(RESOLVED, encoding="utf-8") as fh:
        d = json.load(fh)
    raw = d.get("pins") or d.get("object", {}).get("pins", [])
    out = []
    for p in raw:
        ident = (p.get("identity") or p.get("package") or "").lower()
        loc = p.get("location") or p.get("repositoryURL") or ""
        state = p.get("state", {})
        ver = state.get("version") or state.get("revision", "")[:12] or "unpinned"
        out.append((ident, loc.rstrip("/").removesuffix(".git"), ver))
    return sorted(out)


def build():
    entries = []
    missing = []
    for ident, url, ver in pins():
        # Checkout directory casing does not match the identity.
        hit = None
        if os.path.isdir(CHECKOUTS):
            for e in os.listdir(CHECKOUTS):
                if e.lower() == ident:
                    hit = os.path.join(CHECKOUTS, e)
                    break
        if not hit:
            missing.append(ident)
            continue
        lic_name, lic = read_first(hit, "LICENSE", "LICENCE", "COPYING")
        not_name, notice = read_first(hit, "NOTICE")
        if not lic:
            missing.append(ident)
            continue
        entries.append((ident, url, ver, licence_kind(lic), lic, notice))

    if missing:
        print("FATAL: no licence text found for: " + ", ".join(missing),
              file=sys.stderr)
        print("       Run `swift build` so the checkouts exist, then retry.",
              file=sys.stderr)
        return None

    body = [HEADER]
    body.append("| Package | Version | Licence |")
    body.append("|---|---|---|")
    for ident, url, ver, kind, _lic, _n in entries:
        body.append("| [%s](%s) | %s | %s |" % (ident, url, ver, kind))
    body.append("")
    for ident, url, ver, kind, lic, notice in entries:
        body.append("---")
        body.append("")
        body.append("## %s" % ident)
        body.append("")
        body.append("%s, version %s, %s" % (url, ver, kind))
        body.append("")
        if notice:
            body.append("### NOTICE")
            body.append("")
            body.append("```")
            body.append(notice)
            body.append("```")
            body.append("")
        body.append("### Licence")
        body.append("")
        body.append("```")
        body.append(lic)
        body.append("```")
        body.append("")
    return "\n".join(body).rstrip() + "\n"


def main():
    text = build()
    if text is None:
        return 2
    check = "--check" in sys.argv
    existing = None
    if os.path.exists(OUT):
        with open(OUT, encoding="utf-8") as fh:
            existing = fh.read()
    if check:
        if existing == text:
            print("THIRD-PARTY-NOTICES.md is current (%d dependencies)"
                  % len(pins()))
            return 0
        print("FAIL: THIRD-PARTY-NOTICES.md is stale or missing.", file=sys.stderr)
        print("      Run: python3 Grux-Mac/scripts/gen-third-party-notices.py",
              file=sys.stderr)
        return 1
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote %s (%d dependencies, %d bytes)"
          % (os.path.relpath(OUT, REPO_ROOT), len(pins()), len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
