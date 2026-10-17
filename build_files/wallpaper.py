#!/usr/bin/env python3
"""Draws Juniper's wallpaper (juniper-berry.svg): a stratified gradient. Gently waving bands
stack down the screen, from deep navy at the top through violet into pink, each with a faint
lighter edge, so the gradient reads as layers. `just wallpaper` regenerates the SVG and its
3840x2160 PNG; DMS derives the desktop's colours from the PNG (matugen). Original artwork for
Juniper, CC0-1.0."""
import math

W, H = 1920, 1080
# Top to bottom: each band's colour; band k's top edge sits lower and waves a little differently
BANDS = ("#0b0d2a", "#16134a", "#271761", "#3d1a78", "#5a1d86", "#7d2290",
         "#a12a96", "#c53a9a", "#e2569f")


def edge(k):
    """Band k's top edge: a gentle wave, tilted slightly down to the right."""
    n = len(BANDS)
    base = H * (k / n) * 1.02 - 40
    amp = 26 + 10 * math.sin(k * 1.7)
    freq = 1.1 + 0.25 * math.cos(k * 2.3)
    phase = k * 0.9
    pts = []
    for i in range(0, 97):
        x = W * i / 96
        y = base + 70 * (x / W) + amp * math.sin(2 * math.pi * freq * x / W + phase)
        pts.append((x, y))
    return pts


layers = []
for k, colour in enumerate(BANDS):
    if k == 0:
        layers.append(f'<rect width="{W}" height="{H}" fill="{colour}"/>')
        continue
    pts = edge(k)
    top = " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    layers.append(f'<path d="M{top} L{W},{H} L0,{H} Z" fill="{colour}"/>')
    layers.append(f'<path d="M{top}" fill="none" stroke="#ffffff" stroke-opacity="0.09" '
                  'stroke-width="2"/>')

print(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
<!-- Juniper's wallpaper: a stratified navy-to-pink gradient. Original artwork for Juniper, CC0-1.0. -->
<defs>
<linearGradient id="sheen" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#000000" stop-opacity="0.25"/><stop offset="0.6" stop-color="#000000" stop-opacity="0"/><stop offset="1" stop-color="#ff7ac0" stop-opacity="0.12"/></linearGradient>
</defs>
{"".join(layers)}
<rect width="{W}" height="{H}" fill="url(#sheen)"/>
</svg>''')
