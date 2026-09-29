#!/usr/bin/env python3
"""Design token ceiling. Counts hardcoded fonts, colors, paddings and radii in
Sources/Grux outside DesignSystem/, and fails when any count rises above the
recorded baseline. A count that falls is NOT recorded by --check: the ceiling
stays at the baseline until someone runs --write-baseline, so until then a later
change may add back up to what was removed without failing.

  --check           (default) print each count against the baseline; exit 1
                    when any count rose, 0 otherwise. Never writes. When a
                    count fell it prints a hint to run --write-baseline.
  --write-baseline  record the current counts as the baseline. The only mode
                    that writes the JSON.
  --root DIR        the package folder to scan (default: the current folder).
  --baseline FILE   the baseline JSON (default: ROOT/scripts/design-ratchet-baseline.json).

Run from the Grux-Mac folder. CI runs --check beside the contract check.
The summary line is fixed, a transcript judge reads it:
  design-ratchet: fonts A/B colors C/D paddings E/F radii G/H ok|rose exit N
where each pair is the current count over the baseline.
"""
import argparse
import json
import os
import re
import sys

PATTERNS = {
    "fonts": re.compile(r"\.font\(\.system\(size:|\.font\(\.(largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?)\b"),
    "colors": re.compile(r"Color\.(white|black)\.opacity\(|Color\(red:|\.foregroundStyle\(\.(secondary|tertiary|primary)\)|Color\.(green|red|blue|orange|yellow|gray|purple|pink|cyan|mint|teal|indigo|brown|primary|secondary)\b"),
    "paddings": re.compile(r"\.padding\((\.[a-zA-Z]+, *)?\d"),
    "radii": re.compile(r"\.cornerRadius\(\d|RoundedRectangle\(cornerRadius: *\d"),
}


def count(root):
    src = os.path.join(root, "Sources", "Grux")
    exempt = os.path.join(src, "DesignSystem")
    totals = {k: 0 for k in PATTERNS}
    for dirpath, dirnames, files in os.walk(src):
        if dirpath == exempt or dirpath.startswith(exempt + os.sep):
            dirnames[:] = []
            continue
        for f in files:
            if not f.endswith(".swift"):
                continue
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                text = fh.read()
            for k, rx in PATTERNS.items():
                totals[k] += sum(1 for _ in rx.finditer(text))
    return totals


def summary(now, base, verdict, code):
    pairs = " ".join(f"{k} {now[k]}/{base.get(k, 0)}" for k in PATTERNS)
    return f"design-ratchet: {pairs} {verdict} exit {code}"


def main():
    ap = argparse.ArgumentParser(description="Fails when a hardcode count rises above the recorded baseline.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--baseline")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    baseline = args.baseline or os.path.join(root, "scripts", "design-ratchet-baseline.json")
    now = count(root)

    if args.write_baseline:
        os.makedirs(os.path.dirname(os.path.abspath(baseline)), exist_ok=True)
        with open(baseline, "w") as fh:
            json.dump(now, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(summary(now, now, "ok", 0))
        print(f"design-ratchet: baseline written to {args.baseline or 'scripts/design-ratchet-baseline.json'}")
        return 0

    if not os.path.exists(baseline):
        print(f"design-ratchet: no baseline at {baseline}; run --write-baseline first")
        return 2
    with open(baseline) as fh:
        base = json.load(fh)
    rose = [k for k in PATTERNS if now[k] > base.get(k, 0)]
    fell = [k for k in PATTERNS if now[k] < base.get(k, 0)]
    for k in rose:
        print(f"design-ratchet: {k}: {now[k]} > {base.get(k, 0)} (hardcoded {k} went UP; use the DesignSystem tokens)")
    for k in fell:
        print(f"design-ratchet: {k}: {now[k]} < {base.get(k, 0)} (fell; run python3 scripts/design-ratchet.py --write-baseline to lower the ceiling)")
    code = 1 if rose else 0
    print(summary(now, base, "rose" if rose else "ok", code))
    return code


if __name__ == "__main__":
    sys.exit(main())
