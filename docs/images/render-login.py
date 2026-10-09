#!/usr/bin/env python3
# Renders docs/images/login.svg: a mock Pi 5 login (logo + system summary + Juniper status).
#   docs/images/render-login.py system_files_dev/usr/share/juniper/logo.txt docs/images/login.svg
import re, html, sys, subprocess
logo_src=open(sys.argv[1]).read().rstrip('\n').split('\n')
CW,CH=9.6,20.0; X0,Y0=24,24
COL={'1':'#3fb950','2':'#4a6bd8','3':'#a9bdf5'}
TXT='#c9d1d9'; KEY='#3fb950'; BG='#0d1117'
rects=[]; soft=[]
def R(x,y,w,h,f): rects.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" fill="{f}"/>')
for r,line in enumerate(logo_src):
    col='1'; c=0; i=0
    while i<len(line):
        if line[i]=='$' and i+1<len(line) and line[i+1].isdigit(): col=line[i+1]; i+=2; continue
        ch=line[i]; x=X0+c*CW; y=Y0+r*CH; f=COL[col]
        if ch=='█': R(x,y,CW,CH,f)
        elif ch=='▀': R(x,y,CW,CH/2,f)
        elif ch=='▄': R(x,y+CH/2,CW,CH/2,f)
        elif ch=='▌': R(x,y,CW/2,CH,f)
        elif ch=='▐': R(x+CW/2,y,CW/2,CH,f)
        elif ch=='▟': soft.append(f'<polygon points="{x+CW:.1f},{y:.1f} {x+CW:.1f},{y+CH:.1f} {x:.1f},{y+CH:.1f}" fill="{f}"/>')
        elif ch=='▙': soft.append(f'<polygon points="{x:.1f},{y:.1f} {x:.1f},{y+CH:.1f} {x+CW:.1f},{y+CH:.1f}" fill="{f}"/>')
        elif ch=='▖': R(x,y+CH/2,CW/2,CH/2,f)
        elif ch=='▗': R(x+CW/2,y+CH/2,CW/2,CH/2,f)
        elif ch=='▘': R(x,y,CW/2,CH/2,f)
        elif ch=='▝': R(x+CW/2,y,CW/2,CH/2,f)
        c+=1; i+=1
logo_w=max(len(re.sub(r'\$\d','',l)) for l in logo_src)
info=[("title",None),("sep",None),("OS","Juniper 20261009 aarch64"),("Host","Raspberry Pi 5 Model B Rev 1.0"),
 ("Kernel","Linux 6.12.47-v8.2.el10"),("Uptime","3 days, 4 hours, 12 mins"),("CPU","BCM2712 (4) @ 2.40 GHz - 51.6°C"),
 ("Memory","1.12 GiB / 3.95 GiB (28%)"),("Swap","0 B / 1.97 GiB (0%)"),("Disk (/var)","6.84 GiB / 57.3 GiB (12%) - xfs"),("Local IP (wlan0)","192.168.1.42/24")]
texts=[]; ix=X0+(logo_w+3)*CW
def T(x,y,parts):
    sp=''.join('<tspan fill="%s"%s>%s</tspan>'%(c,' font-weight="bold"' if b else '',html.escape(s)) for s,c,b in parts)
    return f'<text x="{x:.1f}" y="{y:.1f}" xml:space="preserve">{sp}</text>'
top=max(0,(len(info)-len(logo_src))//2)
lt=max(0,(len(logo_src)-len(info))//2)
for r,(k,v) in enumerate(info):
    y=Y0+(r+lt)*CH+CH*0.75
    if k=="title": texts.append(T(ix,y,[("juniper",KEY,True),("@",TXT,False),("juniper",KEY,True)]))
    elif k=="sep": texts.append(T(ix,y,[("-"*15,TXT,False)]))
    else: texts.append(T(ix,y,[(k,KEY,True),(": "+v,TXT,False)]))
rows=max(len(logo_src),len(info))
motd=[("Image","Juniper 20261009"),("Tailscale","100.101.7.42 (firewall: Tailscale only)"),
 ("Update","staged, reboots Sat 2026-10-10 04:37:12 BST"),("Tip","`ujust pi-status` shows temperature and throttling.")]
y0=Y0+(rows+1)*CH
for r,(k,v) in enumerate(motd): texts.append(T(X0+2*CW,y0+r*CH+CH*0.75,[(f"{k:<10} ",KEY,True),(v,TXT,False)]))
texts.append(T(X0+2*CW,y0+(len(motd)+1)*CH+CH*0.75,[("ujust for commands · ujust toggle-motd to hide this",'#8b949e',False)]))
W=int(ix+52*CW+X0); H=int(y0+(len(motd)+2)*CH+Y0)
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'DejaVu Sans Mono',monospace" font-size="16">
<title>Juniper login: logo, system summary and status</title>
<rect width="{W}" height="{H}" rx="10" fill="{BG}"/>
<g transform="translate(0,{top*CH})"><g shape-rendering="crispEdges">
{chr(10).join(rects)}
</g>
{chr(10).join(soft)}
</g>
{chr(10).join(texts)}
</svg>
'''
open(sys.argv[2],'w').write(svg)
if len(sys.argv)>3: subprocess.run(['rsvg-convert','-o',sys.argv[3],sys.argv[2]],check=True)
