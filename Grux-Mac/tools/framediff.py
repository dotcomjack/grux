"""Percent of sampled pixels that differ between two window captures.

Used by grux-sweep.sh to prove a tab actually REPAINTED before the screenshot is
trusted. The app's ack fires when `requestedTab` is set, which is before SwiftUI
draws, so an ack alone will hand you the previous tab's pixels.

Compares only the DETAIL PANE, right of the nav rail. The rail is identical
between tabs and, at 240 of 840 points, it dilutes a whole-window diff enough
that a real tab switch measured only 8%. Sampling the region that actually
changes is both more honest and faster.

    python3 framediff.py A.png B.png [rail_fraction]

`rail_fraction` is where the detail pane starts, as a fraction of image width.
It defaults to 0.32, which is correct at the 840pt floor ((240 rail + divider +
margin) / 840). Pass it explicitly at other window sizes: at 2400pt the rail is
only 0.10 of the width, and the 840pt default would silently discard a third of
the pane being compared. The fraction is scale invariant, so the same value is
right on Retina and non-Retina captures.

Measures EVERY pixel in the region, not a sparse grid. An earlier version
sampled every 29th pixel in each direction.

Worth recording why that was changed, because the obvious explanation was wrong.
Speakers to Contacts, an empty state against a 976-row list, scored 6 on the
sparse grid and was rejected as "NEVER DIVERGED". Sparse sampling looked like
the culprit. It was not: measuring every pixel scores the same transition 7. The
real reason is that these screens are mostly dark background with thin text, so
the fraction of pixels that genuinely change is small even when a human sees two
completely different screens. Exhaustive measurement is still the right default
because it removes sampling as a variable, but it did not move the number, and
the threshold in grux-sweep.sh is what actually had to change.

Prints the COUNT of changed pixels, not a percentage, and the difference is the
whole point. A percentage is scale dependent: it divides by the pane area, so
the same content change scores lower in a bigger window. Measured on the very
same transition, Speakers to Contacts:

    840pt floor    104,963 changed px    8%
    2400pt wide    168,950 changed px    2%

The wide switch changed MORE pixels and scored LOWER, and fell under a threshold
tuned at the floor. Chasing that with a smaller percentage just moves the
failure to the next window size. The count does not move: a stale frame measures
exactly 0 and every real tab switch measured here is above 100,000.

Returns a large sentinel when the frames cannot be compared (unreadable file, or
mismatched sizes because the window was resized mid-sweep), so the caller treats
them as different rather than spinning until it times out.
"""
import sys

from PIL import Image, ImageChops

a, b = sys.argv[1], sys.argv[2]
rail_frac = float(sys.argv[3]) if len(sys.argv) > 3 else 0.32
# Clamp: a bad fraction must not sample zero columns and report a false 0.
rail_frac = min(max(rail_frac, 0.0), 0.9)

UNCOMPARABLE = 10 ** 9

try:
    ia = Image.open(a).convert("RGB")
    ib = Image.open(b).convert("RGB")
except Exception:
    # No baseline yet, or an unreadable capture. Report "totally different" so
    # the caller accepts the frame rather than spinning until it times out.
    print(UNCOMPARABLE)
    sys.exit(0)

if ia.size != ib.size:
    print(UNCOMPARABLE)
    sys.exit(0)

w, h = ia.size
# Skip the top 6%: the toolbar and window chrome are near identical between
# tabs, and a clock in the title area ticks on its own.
box = (int(w * rail_frac), int(h * 0.06), w, h)
ia = ia.crop(box)
ib = ib.crop(box)

# Per-channel absolute difference, flattened to one intensity per pixel. `max`
# rather than a luminance convert, so a change confined to a single channel (an
# accent colour swapping hue at constant brightness) still registers.
d = ImageChops.difference(ia, ib)
flat = ImageChops.lighter(ImageChops.lighter(d.getchannel("R"), d.getchannel("G")),
                          d.getchannel("B"))
# 8 per channel is comfortably above PNG-roundtrip and subpixel-AA noise, and
# far below any real content change.
hist = flat.point(lambda p: 255 if p > 8 else 0).histogram()
print(hist[255])
