#!/usr/bin/env python3
"""Regenerate the counts in README.md that something else derives from.

WHY THIS EXISTS. `README.md` carries `swift test  # NNNN tests`, and
`gruxai.com` reads the site's test count from exactly that line. That makes
the README a DATA SOURCE, and a number typed by hand into a data source rots
silently. It did: the line said 3005 while the suite ran 3,137, so a release
would have published a count that was wrong by 132 and nothing would have
complained.

The house rule is that counts are derived and never typed. This is how that
rule reaches a markdown file.

    python3 scripts/update-readme-counts.py            # runs the suite, rewrites the line
    python3 scripts/update-readme-counts.py --count N  # when you already ran it
    python3 scripts/update-readme-counts.py --check    # exit 1 if the line is stale

`--check` is the one for CI: it fails rather than edits, so a drifted count is
a red build instead of a surprise on release day.
"""
import argparse, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAC = os.path.dirname(HERE)
README = os.path.join(os.path.dirname(MAC), "README.md")
# The exact shape gruxai.com's fetch-facts.py greps for. Do not change it
# without telling whoever maintains that script.
PATTERN = re.compile(r"(swift test\s+#\s*)(\d+)( tests)")


def measured() -> int:
    """Run the suite and read the executed count out of its own output."""
    out = subprocess.run(["swift", "test"], cwd=MAC, capture_output=True, text=True)
    hits = re.findall(r"Executed (\d+) tests", out.stdout + out.stderr)
    if not hits:
        sys.exit("FAIL: could not read an executed-test count from `swift test`.\n"
                 "      A run that reports no count is a failure, never a pass:\n"
                 "      writing 0 into the README would publish 0 to the site.")
    # The suite prints the total several times; they agree, take the largest.
    return max(int(h) for h in hits)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    with open(README, encoding="utf-8") as fh:
        text = fh.read()
    found = PATTERN.search(text)
    if not found:
        sys.exit(f"FAIL: no `swift test  # NNNN tests` line in {README}.\n"
                 "      gruxai.com derives its test count from that line. If it moved,\n"
                 "      fix PATTERN here AND tell whoever maintains fetch-facts.py.")
    current = int(found.group(2))
    n = args.count if args.count is not None else measured()

    if args.check:
        if current != n:
            print(f"STALE: README says {current} tests, the suite ran {n}.")
            print("       Run `python3 scripts/update-readme-counts.py` to fix it.")
            return 1
        print(f"ok: README and the suite agree at {n} tests")
        return 0

    if current == n:
        print(f"ok: already {n}, nothing to do")
        return 0
    with open(README, "w", encoding="utf-8") as fh:
        fh.write(PATTERN.sub(lambda m: f"{m.group(1)}{n}{m.group(3)}", text, count=1))
    print(f"README updated: {current} -> {n} tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
