#!/usr/bin/env python3
"""Draws Juniper's wallpaper (juniper-berry.svg): a juniper berry cluster with needle sprigs in
blues and purples. `just wallpaper` regenerates the SVG and its 3840x2160 PNG; DMS derives the
desktop's colours from the PNG (matugen). Original artwork for Juniper, CC0-1.0."""
import math

W, H = 1920, 1080
CX, CY = 960, 600
R = 64


def berry_positions():
    pos = []
    for n, dy in ((2, -1), (3, 0), (2, 1)):
        for i in range(n):
            pos.append((CX + (i - (n - 1) / 2) * 2 * R * 1.02, CY + dy * R * 1.76))
    pos.append((CX, CY + 2 * R * 1.76))
    return pos


def berry(x, y, i):
    s = f'<g transform="translate({x:.1f},{y:.1f})">'
    s += f'<circle r="{R}" fill="url(#b{i % 3})"/>'
    s += f'<circle r="{R * 0.92:.1f}" fill="url(#bloom)"/>'
    hx, hy = -R * 0.32, -R * 0.36
    s += (f'<ellipse cx="{hx:.1f}" cy="{hy:.1f}" rx="{R * 0.22:.1f}" ry="{R * 0.13:.1f}" '
          f'fill="#dfe4ff" opacity="0.45" transform="rotate(-30 {hx:.1f} {hy:.1f})"/>')
    # The three-pointed scar at a juniper berry's tip
    s += '<g stroke="#241f5c" stroke-width="3" stroke-linecap="round" opacity="0.7">'
    for k in range(3):
        a = math.radians(90 + 120 * k)
        s += (f'<line x1="0" y1="{R * 0.5:.1f}" x2="{R * 0.15 * math.cos(a):.1f}" '
              f'y2="{R * 0.5 + R * 0.15 * math.sin(a):.1f}"/>')
    return s + "</g></g>"


def sprig(x0, y0, ang, length, bend):
    """A stem curving by `bend` degrees, with needles in pairs along it."""
    pts = []
    for k in range(41):
        t = k / 40
        a = math.radians(ang + bend * t)
        pts.append((x0 + math.cos(a) * length * t, y0 - math.sin(a) * length * t))
    out = ['<path d="M' + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
           + '" fill="none" stroke="#4d6fa3" stroke-width="7" stroke-linecap="round"/>']
    for k in range(4, 41, 3):
        x, y = pts[k]
        t = k / 40
        a = ang + bend * t
        nl = 56 * (1 - 0.5 * t)
        for side in (-1, 1):
            b = math.radians(a + side * 48)
            out.append(f'<line x1="{x:.1f}" y1="{y:.1f}" x2="{x + math.cos(b) * nl:.1f}" '
                       f'y2="{y - math.sin(b) * nl:.1f}" stroke="url(#needle)" '
                       'stroke-width="4" stroke-linecap="round"/>')
    return "".join(out)


pos = berry_positions()
top = pos[0][1] - R * 0.85
print(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
<!-- Juniper's wallpaper: a juniper berry cluster. Original artwork for Juniper, CC0-1.0. -->
<defs>
<radialGradient id="bg" cx="50%" cy="52%" r="75%"><stop offset="0" stop-color="#2b2660"/><stop offset="0.55" stop-color="#1a1740"/><stop offset="1" stop-color="#0d0b22"/></radialGradient>
<radialGradient id="b0" cx="38%" cy="32%" r="75%"><stop offset="0" stop-color="#8d9cf2"/><stop offset="0.6" stop-color="#5a62cf"/><stop offset="1" stop-color="#33318f"/></radialGradient>
<radialGradient id="b1" cx="38%" cy="32%" r="75%"><stop offset="0" stop-color="#a08ff0"/><stop offset="0.6" stop-color="#6c55c9"/><stop offset="1" stop-color="#3a2a8a"/></radialGradient>
<radialGradient id="b2" cx="38%" cy="32%" r="75%"><stop offset="0" stop-color="#7fb0f0"/><stop offset="0.6" stop-color="#4f6fd0"/><stop offset="1" stop-color="#2a3a8f"/></radialGradient>
<radialGradient id="bloom" cx="45%" cy="40%" r="60%"><stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
<linearGradient id="needle" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6f9fd4"/><stop offset="1" stop-color="#4a5fb0"/></linearGradient>
<radialGradient id="glow" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#6c5ce0" stop-opacity="0.28"/><stop offset="1" stop-color="#6c5ce0" stop-opacity="0"/></radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<circle cx="{CX}" cy="{CY + 60}" r="430" fill="url(#glow)"/>
{sprig(CX - 10, top, 108, 250, 26)}
{sprig(CX + 10, top, 72, 250, -26)}
{"".join(berry(x, y, i) for i, (x, y) in enumerate(pos))}
</svg>''')
