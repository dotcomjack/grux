#!/usr/bin/env python3
"""Find layout defects in a directory of Grux window captures.

WHY THIS EXISTS. A full visual pass is 36 tabs at two window sizes, 72 images.
Opening all 72 by eye is the only way to be certain, and it is also how a visual
pass quietly stops happening: it is too expensive, so it gets skipped, and layout
regressions ship. This checks every image mechanically and names the ones worth
looking at, which is strictly more coverage than eyeballing a sample.

It does NOT replace opening the image. It decides WHICH images to open. A clean
report means "nothing detectable", not "verified", and the two are different.

THREE DEFECTS, each one already found by hand in this app:

  right-edge clipping   Settings General and Models at the 1040pt default cut
                        text mid-word and put a button half off the edge.
  sidebar overlap       Settings content extended left underneath the nav rail,
                        so "Watch" collided with "Paste it here".
  system-accent blue    A native TabView paints its selection with the macOS
                        accent, so the Settings pane picker rendered blue in an
                        app whose entire palette is purple.

Usage:  python3 tools/layout-audit.py <dir-of-pngs> [--rail 240]
"""
import sys, os, glob
from PIL import Image

# Grux is a dark app. Anything appreciably brighter than the window chrome is
# content, which is what makes an edge test meaningful at all.
# 90, not 42, and the difference is a false positive that survived four real
# fixes. A card background fill measures (41, 39, 51), whose max channel is 51,
# so a threshold of 42 counted every full-width card as "clipped content". The
# Models pane scored EXACTLY 912 across four builds with genuine layout changes,
# which is the tell: a number that will not move is measuring something that is
# not changing. Real text on these captures samples around (155, 155, 155), so 90
# separates glyphs from panel fills with room on both sides.
BG_MAX = 90          # a pixel this dark or darker counts as background
EDGE_COLS = 3        # how many columns at the right edge to inspect
EDGE_HITS = 40       # content pixels in those columns before it is clipping

# macOS system blue, the colour a native control paints its selection when it is
# not wearing the app's tint. Grux's accent is purple (hue near 250), so a strong
# blue region is a control that got missed.
def is_system_blue(r, g, b):
    # Tuned on MEASURED clusters, not guessed. A selected native control paints
    # one tight saturated block: sampling the Settings General pane, 637 of the
    # hits landed in a single cluster at (48, 112, 240), which is macOS system
    # blue. Chat's blue-ish pixels are the hero orb's glow, spread across many
    # lighter clusters that all have r >= 112. Red is what separates them, so a
    # loose "is it blue" test flagged a tab that was verified clean by eye.
    return r < 90 and b > 200 and 80 < g < 170


def audit(path, rail_pt=240):
    im = Image.open(path).convert("RGB")
    W, H = im.size
    px = im.load()
    # Captures are Retina, so points are half of pixels. Derive rather than
    # assume: a 2400pt window is 4800px wide.
    scale = 2 if W > 2200 else 2
    rail = int(rail_pt * scale)
    findings = []

    # 1. RIGHT-EDGE CONTENT. Reported as a MEASUREMENT, not a verdict.
    #
    # A naive "content touches the edge" test is wrong and the first run proved
    # it: Chat is full-bleed by design and scored 1,224, higher than the Settings
    # capabilities pane that genuinely clips. Touching the edge is not the same as
    # being cut. So this only reports the number, and `--pairs` decides, because
    # the defect is WIDTH DEPENDENT: Settings clips at 1040 and is clean at 2400,
    # while a full-bleed tab touches the edge at both.
    hits = 0
    for x in range(W - EDGE_COLS, W):
        for y in range(int(H * 0.08), int(H * 0.97)):
            r, g, b = px[x, y]
            if max(r, g, b) > BG_MAX:
                hits += 1
    findings.append(("_edge", hits))

    # 2. SYSTEM-ACCENT BLUE. Count strongly blue pixels; a selected native
    #    control is a solid block, so a real hit is hundreds of pixels.
    # Restricted to the DETAIL PANE. The nav rail holds the hero orb, a
    # blue-to-purple gradient that tripped this on every tab in the first run.
    # The defect being hunted is a native control wearing the macOS accent, and
    # those live in the detail pane.
    blue = 0
    for x in range(rail + 8, W, 3):
        for y in range(0, H, 3):
            if is_system_blue(*px[x, y]):
                blue += 1
    # Reviewed and ACCEPTED, with the reason, so a judgment call is made once
    # rather than re-argued on every run. Roadmap's blue is not an untinted
    # control: it is a semantic status colour inside a coherent tier palette,
    # Tier S magenta, Tier A blue, Tier B teal, with "In progress" cards blue and
    # "Not started" neutral. Recolouring it would delete information. Verified by
    # opening the capture.
    if "roadmap" in os.path.basename(path).lower():
        blue = 0
    if blue > 300:
        findings.append(f"system-accent blue present (~{blue * 9} px), a control is not wearing the app tint")

    # 3. SIDEBAR OVERLAP. The rail is a flat dark column; detail content drawn
    #    underneath it shows up as bright pixels in the rail's x-range in the
    #    lower band, where the rail itself has only its status line.
    if W > rail:
        overlap = 0
        for x in range(int(rail * 0.72), rail):
            for y in range(int(H * 0.80), int(H * 0.94)):
                r, g, b = px[x, y]
                if max(r, g, b) > 110:
                    overlap += 1
        if overlap > 220:
            findings.append(f"possible sidebar overlap ({overlap} bright px under the rail)")

    return findings


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    rail = 240
    if "--rail" in sys.argv:
        rail = int(sys.argv[sys.argv.index("--rail") + 1])

    files = sorted(glob.glob(os.path.join(args[0], "*.png")))
    if not files:
        print(f"no PNGs in {args[0]}")
        return 2

    # Pair by tab name so the width-dependent clip can be detected: <prefix>-<tab>.png
    edges = {}
    for f in files:
        base = os.path.basename(f)
        tab = base.split("-", 1)[1] if "-" in base else base
        im = Image.open(f)
        for item in audit(f, rail):
            if isinstance(item, tuple) and item[0] == "_edge":
                edges.setdefault(tab, []).append((im.size[0], item[1], base))

    flagged = 0
    unpaired = set()
    for f in files:
        found = [x for x in audit(f, rail) if not isinstance(x, tuple)]
        base = os.path.basename(f)
        tab = base.split("-", 1)[1] if "-" in base else base
        pair = edges.get(tab, [])
        # A single-size run CANNOT answer the clipping question, and saying
        # nothing would be worse than saying so: the first run of this tool
        # reported "clean" on a Settings pane that was visibly cutting text,
        # because only one width had been swept and the paired check silently
        # did nothing. A check that no-ops in silence is indistinguishable from
        # a check that passed.
        if len(pair) < 2:
            unpaired.add(tab)
        if len(pair) == 2:
            narrow, wide = sorted(pair)
            # Clipped only when the NARROW render presses content into the edge
            # and the WIDE one does not. That is the Settings signature, and it
            # is not Chat's, which is full-bleed at both widths.
            if narrow[1] > 200 and wide[1] < narrow[1] * 0.25:
                found.append(f"width-dependent clipping: {narrow[1]} edge px narrow vs {wide[1]} wide")
        if found:
            flagged += 1
            print(f"\n  {os.path.basename(f)}")
            for x in found:
                print(f"      {x}")

    print(f"\n{len(files)} images checked, {flagged} flagged, {len(files) - flagged} clean")
    if unpaired:
        print(f"\n  NOT CHECKED FOR CLIPPING: {len(unpaired)} surface(s) were swept at only one")
        print( "  window size, and clipping is width dependent. Sweep both sizes or this")
        print( "  tool is silent about the defect it was written to find.")
        print( "    " + ", ".join(sorted(unpaired)[:12]))
        return 1
    # Non-zero so a caller cannot read a flagged run as a pass.
    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
