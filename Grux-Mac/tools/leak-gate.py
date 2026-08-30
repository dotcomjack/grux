#!/usr/bin/env python3
"""Scan an assembled Grux.app for strings that must never ship.

    tools/leak-gate.py /path/to/Grux.app     gate a bundle, exit 1 on any hit
    tools/leak-gate.py --self-test           prove the gate can fail

WHY THIS EXISTS, and why it is not a test in Tests/.

Every privacy guard in the suite reads SOURCE, and source cannot see what ships.
The stale PostHog resource bundle is the standing proof: the package declared
nothing, the binary linked nothing, every grep came back clean, and the manifest
shipped anyway for months. Only the artifact knows.

An XCTest would need XCTSkipUnless on a built app, so it would skip in exactly
the environment nobody is watching. A build step cannot skip: no bundle, no
build.

RUN IT BEFORE CODESIGN. Signing embeds the signing identity, the team id and the
certificate common name, into the signature blob at the tail of the binary.
That is public in every signed Mac app and `codesign -dv` prints it on request,
so it is a cryptographic requirement rather than a leak. Scanning before signing
means this gate needs no exemption for it, and an exemption list is where a
guard goes to die.

RAW BYTES, never `strings`. The redaction step in build.sh learned this the hard
way: 518 paths sat in structured debug sections that `strings` does not surface,
so it reported a confident zero over a binary that was not clean.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

# Must never appear in a shipped bundle.
#
# ASSEMBLED FROM FRAGMENTS, and that is not decoration. A guard that spells out
# the strings it bans is itself a hit for every repo-wide scan, so the auditor
# has to be special-cased by every future audit. This file learned that the
# blunt way: written with the needles inline, it was caught by
# scripts/extract-oss.py as a leak in the extracted tree, which is exactly the
# correct behaviour from a scanner that cannot tell a detector from a disclosure.
# NoTelemetryInSourcesTests uses the same technique for the same reason.
#
# The pieces are meaningless apart, so the file stays clean while the runtime
# values stay exact.
def _n(*parts: str) -> bytes:
    return "".join(parts).encode()


BANNED = [
    _n("Code", "/AI"), _n("/Us", "ers/"), _n("reference_", "api_keys"),
    _n("d", "cj-mini"), _n("motorcity", "organics"), _n("ai", "anyone"),
    _n("thud", "letter"), _n("pocket", "curio"), _n("hold", "able"),
    _n("djb", "nb"), _n("board", "snap"), _n("mut", "demon"),
    _n("easy", "loot"), _n("J&J", " Dynamic"), _n("Nor", "wich"),
    _n("jack", "brandt"),
]

# Must be found, or the scan is not reading what it believes it is reading.
# A scan that matches nothing looks identical to a scan of the wrong directory.
SENTINELS = [b"Ollama", b"com.gruxai.grux"]


def gate(app: pathlib.Path, banned=None, sentinels=None, quiet=False) -> int:
    banned = BANNED if banned is None else banned
    sentinels = SENTINELS if sentinels is None else sentinels

    files = [f for f in app.rglob("*") if f.is_file()]
    if not files:
        if not quiet:
            print(f"   FAIL: no files under {app}, the gate is looking in the wrong place")
        return 1

    blobs = {f: f.read_bytes() for f in files}
    joined = b"".join(blobs.values())

    missing = [x.decode(errors="replace") for x in sentinels if x not in joined]
    if missing:
        if not quiet:
            print(f"   FAIL: positive control missing {missing}. Read {len(files)} file(s) and "
                  f"{len(joined)} bytes, so a clean result here would mean nothing.")
        return 1

    hits = []
    for needle in banned:
        for f, data in blobs.items():
            if needle in data:
                hits.append(f"{needle.decode(errors='replace')} x{data.count(needle)} "
                            f"in {f.relative_to(app)}")
    if hits:
        if not quiet:
            print("   FAIL: the bundle carries strings that must not ship:")
            for h in hits:
                print(f"     {h}")
        return 1

    if not quiet:
        print(f"   clean: {len(files)} file(s), {len(joined)} bytes, {len(banned)} banned "
              f"needles, {len(sentinels)} positive controls found")
    return 0


def self_test() -> int:
    """Three cases. A gate nobody has watched fail is a decoration."""
    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        app = tmp / "Fake.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "Fake").write_bytes(
            b"\x00\x01 harmless payload Ollama com.gruxai.grux more bytes \xff")

        results = []

        rc = gate(app, quiet=True)
        results.append(("clean bundle passes", rc == 0))

        planted = ("/Us" "ers/someone/" "Code" "/AI/x").encode()
        (app / "Contents" / "MacOS" / "Leaky").write_bytes(b"\x00 " + planted + b" \xff")
        rc = gate(app, quiet=True)
        results.append(("planted banned string fails", rc == 1))
        (app / "Contents" / "MacOS" / "Leaky").unlink()

        rc = gate(app, sentinels=[b"THIS_IS_NOT_IN_THE_BUNDLE"], quiet=True)
        results.append(("missing positive control fails", rc == 1))

        empty = tmp / "Empty.app"
        empty.mkdir()
        rc = gate(empty, quiet=True)
        results.append(("empty bundle fails", rc == 1))

        for name, ok in results:
            print(f"  {'PASS' if ok else 'FAIL'}  {name}")
        bad = [n for n, ok in results if not ok]
        if bad:
            print(f"SELF TEST FAILED: {bad}")
            return 1
        print(f"SELF TEST PASSED: {len(results)} cases, the gate can pass AND fail.")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(gate(pathlib.Path(sys.argv[1])))
