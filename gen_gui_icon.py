#!/usr/bin/env python3
"""Generate devc-gui.ico - a flat, multi-size icon for the devc container manager.

Motif: a shipping-container / box holding a terminal prompt ("d>"), on a rounded
brand-blue tile. Pure Pillow, no external assets, so the icon is reproducible.

    python gen_gui_icon.py            # writes devc-gui.ico next to this script
    python gen_gui_icon.py out.ico
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SIZES = [16, 32, 48, 64, 128, 256]

BG_TOP    = (37, 99, 235)    # brand blue
BG_BOTTOM = (29, 78, 165)    # darker blue for a subtle vertical gradient
BOX       = (245, 247, 250)  # near-white container body
BOX_EDGE  = (203, 213, 225)  # cool grey edge
ACCENT    = (37, 99, 235)    # prompt colour (matches bg)
LID       = (226, 232, 240)


def _rounded_gradient(size):
    """Rounded-rect tile with a top->bottom gradient, on transparency."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = Image.new("RGBA", (size, size))
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(BG_TOP[0] * (1 - t) + BG_BOTTOM[0] * t)
        g = int(BG_TOP[1] * (1 - t) + BG_BOTTOM[1] * t)
        b = int(BG_TOP[2] * (1 - t) + BG_BOTTOM[2] * t)
        for x in range(size):
            grad.putpixel((x, y), (r, g, b, 255))
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    radius = max(2, int(size * 0.22))
    md.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)
    return img


def _font(px):
    for name in ("consolab.ttf", "consola.ttf", "DejaVuSansMono-Bold.ttf",
                 "DejaVuSansMono.ttf", "arialbd.ttf", "arial.ttf"):
        try:
            return ImageFont.truetype(name, px)
        except Exception:
            continue
    return ImageFont.load_default()


def draw_icon(size):
    img = _rounded_gradient(size)
    d = ImageDraw.Draw(img)

    # container body
    m = size * 0.20
    x0, y0, x1, y1 = m, size * 0.30, size - m, size - m
    d.rounded_rectangle([x0, y0, x1, y1], radius=max(1, int(size * 0.05)),
                        fill=BOX, outline=BOX_EDGE, width=max(1, int(size * 0.015)))

    # lid strip on top of the box
    d.rounded_rectangle([x0, y0 - size * 0.06, x1, y0 + size * 0.02],
                        radius=max(1, int(size * 0.03)), fill=LID, outline=BOX_EDGE,
                        width=max(1, int(size * 0.01)))

    # terminal prompt "d>" inside the box (drop the text at tiny sizes)
    if size >= 32:
        txt = "d>"
        f = _font(int(size * 0.34))
        bb = d.textbbox((0, 0), txt, font=f)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        cx = (x0 + x1) / 2 - tw / 2 - bb[0]
        cy = (y0 + y1) / 2 - th / 2 - bb[1]
        d.text((cx, cy), txt, font=f, fill=ACCENT)
    else:
        # at 16px just draw a chevron so it still reads as a terminal
        d.line([(x0 + size * 0.22, y0 + size * 0.22),
                (x0 + size * 0.42, (y0 + y1) / 2),
                (x0 + size * 0.22, y1 - size * 0.22)],
               fill=ACCENT, width=max(1, int(size * 0.05)))
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "devc-gui.ico")
    base = draw_icon(256)
    imgs = [draw_icon(s) for s in SIZES]
    base.save(out, format="ICO", sizes=[(s, s) for s in SIZES],
              append_images=imgs)
    print("wrote", out, "sizes:", SIZES)


if __name__ == "__main__":
    main()
