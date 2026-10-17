#!/usr/bin/env python3
"""Draws Juniper's default user picture (avatar.svg): the berry logo from the terminal
(fastfetch's logo.txt), pixel for pixel, on the wallpaper's navy-to-pink strata. Each character
cell of logo.txt is 2x2 pixels (half blocks fill halves), drawn twice as tall as wide, like a
terminal cell. `just wallpaper` regenerates the SVG and
its 512x512 PNG; the greeter and DMS show it, clipped to a circle. Original artwork for Juniper,
CC0-1.0. Usage: avatar.py LOGO_TXT"""
import re
import sys

SIZE = 512
STRATA = ("#16134a", "#271761", "#3d1a78", "#5a1d86", "#7d2290", "#a12a96", "#c53a9a", "#e2569f")
# logo.txt colour codes $1 crown, $2 berry, $3 highlight
INK = {"1": "#9df5b0", "2": "#f6b8ea", "3": "#ffffff"}
# which 2x2 sub-pixels each block character fills: (top-left, top-right, bottom-left, bottom-right)
CELLS = {"█": (1, 1, 1, 1), "▀": (1, 1, 0, 0), "▄": (0, 0, 1, 1), "▌": (1, 0, 1, 0), "▐": (0, 1, 0, 1)}


def pixels(text):
    out, colour = [], "1"
    for row, line in enumerate(text.splitlines()):
        col = 0
        for tok in re.split(r"(\$\d)", line):
            if re.fullmatch(r"\$\d", tok):
                colour = tok[1]
                continue
            for ch in tok:
                for k, on in enumerate(CELLS.get(ch, (0, 0, 0, 0))):
                    if on:
                        out.append((col * 2 + k % 2, row * 2 + k // 2, INK[colour]))
                col += 1
    return out


px = pixels(open(sys.argv[1], encoding="utf-8").read())
w = max(x for x, _, _ in px) + 1
h = max(y for _, y, _ in px) + 1
# A terminal cell is about twice as tall as wide, so a sub-pixel is half as wide as tall.
cell = int(SIZE * 0.62 / max(w / 2, h))
cw = cell / 2
ox, oy = (SIZE - w * cw) / 2, (SIZE - h * cell) / 2
bands = "".join(f'<rect y="{i * SIZE / len(STRATA):.1f}" width="{SIZE}" height="{SIZE / len(STRATA) + 1:.1f}" '
                f'fill="{c}"/>' for i, c in enumerate(STRATA))
blocks = "".join(f'<rect x="{ox + x * cw:.1f}" y="{oy + y * cell:.1f}" width="{cw:.1f}" height="{cell}" fill="{c}"/>'
                 for x, y, c in px)
print(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}" shape-rendering="crispEdges">
<!-- Juniper's default user picture: the terminal's berry logo on the wallpaper's strata. Original artwork for Juniper, CC0-1.0. -->
{bands}
<g>{blocks}</g>
</svg>''')
