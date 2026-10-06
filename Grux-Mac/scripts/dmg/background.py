"""Render the Grux DMG window background (run by make-dmg.sh) at 1x and 2x, then join them into one HiDPI TIFF."""
import subprocess, sys
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 400
LEFT, RIGHT, ICON_Y = 170, 470, 200          # icon centres, kept in step with settings.py
BG, INK, DIM, ACCENT = "#F5F5F7", "#0A0A0C", "#6E6E76", "#7B61FF"
FONT = "/System/Library/Fonts/SFNS.ttf"

def render(scale, out):
    s = scale
    im = Image.new("RGB", (W * s, H * s), BG)
    d = ImageDraw.Draw(im)
    title = ImageFont.truetype(FONT, 22 * s); title.set_variation_by_name("Semibold")
    note = ImageFont.truetype(FONT, 13 * s)
    def centred(y, text, font, fill):
        w = d.textlength(text, font=font)
        d.text(((W * s - w) / 2, y * s), text, font=font, fill=fill)
    centred(48, "Drag Grux into Applications", title, INK)
    # Arrow between the two icons, clear of the 128 point icon frames.
    x0, x1, y = (LEFT + 82) * s, (RIGHT - 82) * s, ICON_Y * s
    d.line([(x0, y), (x1 - 14 * s, y)], fill=ACCENT, width=5 * s)
    d.polygon([(x1, y), (x1 - 20 * s, y - 13 * s), (x1 - 20 * s, y + 13 * s)], fill=ACCENT)
    centred(322, "Then open Grux from your Applications folder.", note, DIM)
    centred(342, "Apple silicon, macOS 14 or later. Notarized by Apple.", note, DIM)
    im.save(out, dpi=(72 * s, 72 * s))

render(1, "bg.png"); render(2, "bg@2x.png")
subprocess.run(["tiffutil", "-cathidpicheck", "bg.png", "bg@2x.png", "-out", "background.tiff"], check=True)
print("background.tiff")
