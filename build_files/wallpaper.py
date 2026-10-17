#!/usr/bin/env python3
"""Draws Juniper's wallpaper (juniper-berry.svg): Juniper's logo from the terminal, abstracted
(an open ring under three spokes) in one neon stroke, leaning back from the viewer in perspective,
right of centre with its base pointing at the bottom centre of the screen, on a plain diagonal
gradient. The logo is drawn flat, turned in its plane, then every point is tilted about a
horizontal axis and projected through a pinhole camera. `just wallpaper` regenerates the SVG
and its 3840x2160 PNG; DMS derives the desktop's colours from the PNG (matugen). Original
artwork for Juniper, CC0-1.0."""
import math

W, H = 1920, 1080
CX, CY = 1300, 470          # where the logo's centre lands on screen
TARGET = (W / 2, H)         # the logo's base points here: the bottom centre
TILT_BACK = 38              # degrees the logo leans away from the viewer
CAMERA = 1500               # camera distance; smaller = stronger perspective
SCALE = 1.2
CYAN, MAGENTA = "#55e6ff", "#e45cff"

# Turn the logo so its base (+y in the logo) points from (CX, CY) at TARGET.
SPIN = math.degrees(math.atan2(-(TARGET[0] - CX), TARGET[1] - CY))


def project(x, y):
    """Logo-plane point (centred on the logo, +y toward its base) -> screen point."""
    s = math.radians(SPIN)
    x, y = x * math.cos(s) - y * math.sin(s), x * math.sin(s) + y * math.cos(s)
    x, y = x * SCALE, y * SCALE
    t = math.radians(TILT_BACK)
    yy, z = y * math.cos(t), -y * math.sin(t)
    f = CAMERA / (CAMERA + z)
    return CX + x * f, CY + yy * f


def path(points, closed=False):
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in (project(*p) for p in points))
    return d + (" Z" if closed else "")


# Juniper's logo from the terminal (fastfetch's logo.txt), reduced to geometry: an open ring
# for the berry, broken at the top, and three spokes (a centre stem and two diagonals) rising
# from the gap. One stroke colour, a gradient from cyan to magenta.
BR = 170
GAP = 26                    # degrees each side of the top left open
ring = [(BR * math.cos(math.radians(a)), 60 + BR * math.sin(math.radians(a)))
        for a in range(-90 + GAP, 270 - GAP + 1, 3)]
out = [f'<path d="{path(ring)}"/>']
top = 60 - BR
out.append(f'<path d="{path([(0, top - 30), (0, top - 170)])}"/>')
for side in (-1, 1):
    out.append(f'<path d="{path([(side * 34, top - 22), (side * 120, top - 140)])}"/>')

print(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
<!-- Juniper's wallpaper: Juniper's berry logo in neon, leaning back. Original artwork for Juniper, CC0-1.0. -->
<defs>
<linearGradient id="neon" gradientUnits="userSpaceOnUse" x1="1000" y1="250" x2="1550" y2="800"><stop offset="0" stop-color="{CYAN}"/><stop offset="1" stop-color="{MAGENTA}"/></linearGradient>\n<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#070a1f"/><stop offset="0.5" stop-color="#1b1350"/><stop offset="1" stop-color="#4a1873"/></linearGradient>
<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="9" result="wide"/><feGaussianBlur in="SourceGraphic" stdDeviation="2.5" result="near"/><feMerge><feMergeNode in="wide"/><feMergeNode in="wide"/><feMergeNode in="near"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<g fill="none" stroke="url(#neon)" stroke-width="11" stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)">{"".join(out)}</g>
</svg>''')
