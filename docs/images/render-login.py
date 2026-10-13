#!/usr/bin/env python3
# Render a captured SSH login banner; substitute example network addresses.
from pathlib import Path
import re, html, sys
if len(sys.argv) != 3:
    raise SystemExit('Usage: render-login.py CAPTURE.ansi OUTPUT.svg')
source = Path(sys.argv[1]).read_text()

source = source.rstrip().removesuffix('logout').rstrip()
# Crop optional systemd diagnostics before the coloured Juniper banner.
start = source.find('\x1b[m\x1b[1m\x1b[32m')
if start >= 0:
    source = source[start:]
colors = ['#0d1117','#ff7b72','#3fb950','#d29922','#4a6bd8','#bc8cff','#39c5cf','#c9d1d9']
fg = colors[7]
bold = False
rows = []
for line in source.splitlines():
    cells = []
    for token in re.split(r'(\x1b\[[0-?]*[ -/]*[@-~])',line):
        if token.startswith('\x1b['):
            if token.endswith('m'):
                codes = [int(n) if n else 0 for n in token[2:-1].split(';')]
                for n in codes:
                    if n == 0: fg, bold = colors[7], False
                    elif n == 1: bold = True
                    elif n == 22: bold = False
                    elif n == 39: fg = colors[7]
                    elif 30 <= n <= 37: fg = colors[n-30]
                    elif 90 <= n <= 97: fg = colors[n-90]
            continue
        cells.extend((c,fg,bold) for c in token)
    plain = ''.join(cell[0] for cell in cells)
    for match in reversed(list(re.finditer(r'\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d+)?\b', plain))):
        color, weight = cells[match.start()][1:]
        example = '192.0.2.10/24' if '/' in match.group() else '100.64.0.10'
        cells[match.start():match.end()] = [(char, color, weight) for char in example]
    rows.append(cells)
cw,ch,pad = 9.6,22,24
width = int(max(map(len,rows))*cw+pad*2)
height = len(rows)*ch+pad*2
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace" font-size="16">', '<title>Live SSH login to Juniper on a Raspberry Pi 5</title>', '<desc>Captured from nat@juniper on 13 October 2026. Example network addresses substituted. Cropped to the Juniper login banner and system summary.</desc>', f'<rect width="{width}" height="{height}" rx="10" fill="#0d1117"/>']
blocks={'█':(0,0,1,1),'▀':(0,0,1,.5),'▄':(0,.5,1,.5),'▌':(0,0,.5,1),'▐':(.5,0,.5,1)}
for r,cells in enumerate(rows):
    for c,(char,fg,bold) in enumerate(cells):
        x,y=pad+c*cw,pad+r*ch
        if char in blocks:
            dx,dy,w,h=blocks[char]
            out.append(f'<rect x="{x+dx*cw:.2f}" y="{y+dy*ch:.2f}" width="{w*cw:.2f}" height="{h*ch:.2f}" fill="{fg}" shape-rendering="crispEdges"/>')
        elif char != ' ':
            weight=' font-weight="bold"' if bold else ''
            out.append(f'<text x="{x:.2f}" y="{y+ch*.76:.2f}" fill="{fg}"{weight}>{html.escape(char)}</text>')
out.append('</svg>')
Path(sys.argv[2]).write_text('\n'.join(out)+'\n')
print(f'Rendered {len(rows)} captured terminal rows into {width} × {height} SVG')
