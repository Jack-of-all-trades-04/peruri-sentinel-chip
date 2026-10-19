#!/usr/bin/env python3
"""Generic VCD -> SVG -> PNG waveform renderer for the evidence package.

Panels are defined in Python (see make_panels_*.py). Each panel: title, subtitle,
time window [t0, t1] in ns, a list of rows and optional markers.
Row: dict(label, sig, kind='bit'|'bus'|'clk', fmt='hex'|'dec'|'ct', note='').
Marker: dict(t=ns, text='...', color='#hex').
Indonesian labels, decimal comma, no em dashes.
"""
import html, subprocess, os, tempfile

C = dict(bg='#ffffff', panel='#f7f9fc', grid='#e5e7eb', text='#14213d', sub='#6b7280',
         bit='#2f4168', hi='#dbe4f3', red='#c0392b', redsoft='#fbedee',
         green='#1e8e5a', greensoft='#e6f0ea', amber='#b7791f', ambersoft='#fdf3e1')


class VCD:
    def __init__(self, path, wanted):
        self.ts_ps = 1
        self.data = {w: [] for w in wanted}
        code2names = {}
        scope = []
        with open(path) as f:
            it = iter(f)
            for line in it:
                p = line.split()
                if not p:
                    continue
                if p[0] == '$timescale':
                    s = ''.join(p[1:]).replace('$end', '')
                    if not s:
                        s = next(it).strip()
                    num = int(''.join(ch for ch in s if ch.isdigit()) or '1')
                    unit = ''.join(ch for ch in s if ch.isalpha())
                    self.ts_ps = num * {'s': 10**12, 'ms': 10**9, 'us': 10**6, 'ns': 1000, 'ps': 1, 'fs': 0.001}[unit]
                elif p[0] == '$scope':
                    scope.append(p[2])
                elif p[0] == '$upscope':
                    scope.pop()
                elif p[0] == '$var':
                    full = '.'.join(scope + [p[4]])
                    if full in self.data:
                        code2names.setdefault(p[3], []).append(full)
                elif p[0] == '$enddefinitions':
                    break
            t = 0
            for line in it:
                line = line.strip()
                if not line:
                    continue
                c = line[0]
                if c == '#':
                    t = int(line[1:]) * self.ts_ps / 1000.0
                elif c in '01xzXZ':
                    for n in code2names.get(line[1:], ()):
                        self.data[n].append((t, c.lower()))
                elif c in 'bB':
                    v, code = line[1:].split()
                    for n in code2names.get(code, ()):
                        self.data[n].append((t, v.lower()))
        missing = [w for w, v in self.data.items() if not v]
        if missing:
            raise SystemExit('signals not found in VCD: ' + ', '.join(missing))

    def at(self, name, t):
        v = None
        for tt, vv in self.data[name]:
            if tt <= t:
                v = vv
            else:
                break
        return v

    def changes(self, name, t0, t1):
        out = [(t0, self.at(name, t0))]
        for tt, vv in self.data[name]:
            if t0 < tt < t1:
                out.append((tt, vv))
        return out

    def edges(self, name, val, t0=0, t1=1e18):
        """times where signal becomes val (string compare after int conversion)."""
        res, prev = [], None
        for tt, vv in self.data[name]:
            iv = ival(vv)
            if t0 <= tt <= t1 and iv == val and prev != val:
                res.append(tt)
            prev = iv
        return res


def ival(v):
    if v is None:
        return None
    try:
        return int(v, 2)
    except ValueError:
        return None


def fmt_val(v, fmt, width_bits=None):
    iv = ival(v)
    if iv is None:
        return 'x'
    if fmt == 'dec':
        return str(iv)
    if fmt == 'bin':
        return format(iv, 'b').zfill(width_bits or len(v))
    if fmt == 'ct':
        h = format(iv, '032x')
        return h[:8] + '..' + h[-4:] if iv else '0'
    return format(iv, 'x')


def tfmt(ns):
    s = f'{ns:,.1f}'
    return s.replace(',', '#').replace('.', ',').replace('#', '.')


def render(vcd, panel, out_png, W=1920):
    t0, t1 = panel['t0'], panel['t1']
    rows = panel['rows']
    LBL = 300
    X0, X1 = LBL + 30, W - 40
    top = 150
    rh = 54
    H = top + rh * len(rows) + 150
    sx = lambda t: X0 + (t - t0) / (t1 - t0) * (X1 - X0)
    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="DejaVu Sans, Arial, sans-serif">')
    o.append(f'<rect width="{W}" height="{H}" fill="{C["bg"]}"/>')
    o.append(f'<text x="40" y="52" font-size="30" font-weight="bold" fill="{C["text"]}">{html.escape(panel["title"])}</text>')
    o.append(f'<text x="40" y="88" font-size="19" fill="{C["sub"]}">{html.escape(panel["subtitle"])}</text>')
    o.append(f'<text x="40" y="118" font-size="16" fill="{C["sub"]}">Jendela waktu: {tfmt(t0)} ns s.d. {tfmt(t1)} ns</text>')
    # shaded regions
    for reg in panel.get('regions', []):
        a, b = sx(max(reg['t0'], t0)), sx(min(reg['t1'], t1))
        o.append(f'<rect x="{a:.1f}" y="{top-10}" width="{max(b-a,1):.1f}" height="{rh*len(rows)+10}" fill="{C[reg.get("color","greensoft")]}" opacity="0.7"/>')
        lw = 8.6 * len(reg["text"]) + 12
        o.append(f'<rect x="{a+2:.1f}" y="{top-8}" width="{lw:.1f}" height="22" rx="4" fill="#ffffff" stroke="{C[reg.get("tcolor","green")]}" stroke-width="1"/>')
        o.append(f'<text x="{a+8:.1f}" y="{top+8}" font-size="15" font-weight="bold" fill="{C[reg.get("tcolor","green")]}">{html.escape(reg["text"])}</text>')
    # time grid
    nt = 8
    for k in range(nt + 1):
        tt = t0 + (t1 - t0) * k / nt
        x = sx(tt)
        o.append(f'<line x1="{x:.1f}" y1="{top-10}" x2="{x:.1f}" y2="{top+rh*len(rows)}" stroke="{C["grid"]}" stroke-width="1"/>')
        o.append(f'<text x="{x:.1f}" y="{top+rh*len(rows)+24}" font-size="14" fill="{C["sub"]}" text-anchor="middle">{tfmt(tt)} ns</text>')
    for i, r in enumerate(rows):
        y = top + i * rh + 12
        yh, yl = y + 6, y + 34
        o.append(f'<text x="40" y="{y+20}" font-size="17" font-weight="bold" fill="{C["text"]}">{html.escape(r["label"])}</text>')
        if r.get('note'):
            o.append(f'<text x="40" y="{y+40}" font-size="13" fill="{C["sub"]}">{html.escape(r["note"])}</text>')
        col = C.get(r.get('color', 'bit'), C['bit'])
        ch = vcd.changes(r['sig'], t0, t1)
        if 'bitidx' in r:
            bi = r['bitidx']
            def pick(v):
                iv = ival(v)
                return 'x' if iv is None else str((iv >> bi) & 1)
            raw = [(tt, pick(vv)) for tt, vv in ch]
            ch = [raw[0]] + [raw[k] for k in range(1, len(raw)) if raw[k][1] != raw[k - 1][1]]
        kind = r.get('kind', 'bit')
        if kind == 'clk':
            per = r.get('period', 20.0)
            ncyc = (t1 - t0) / per
            if ncyc > 160:
                o.append(f'<rect x="{X0}" y="{yh}" width="{X1-X0}" height="{yl-yh}" fill="{C["hi"]}"/>')
                o.append(f'<text x="{(X0+X1)/2}" y="{(yh+yl)/2+5}" font-size="14" fill="{C["bit"]}" text-anchor="middle">clock {r.get("ftext","")} ({int(ncyc)} siklus di jendela ini)</text>')
                continue
            kind = 'bit'
        if kind == 'bit':
            pts = []
            for k, (tt, vv) in enumerate(ch):
                x = sx(tt)
                yy = yh if vv == '1' else yl
                if pts:
                    pts.append(f'{x:.1f},{pts[-1].split(",")[1]}')
                pts.append(f'{x:.1f},{yy}')
                tn = ch[k + 1][0] if k + 1 < len(ch) else t1
                if vv == '1' and r.get('fill', True):
                    o.append(f'<rect x="{x:.1f}" y="{yh}" width="{max(sx(tn)-x,0.5):.1f}" height="{yl-yh}" fill="{col}" opacity="0.15"/>')
            pts.append(f'{X1:.1f},{pts[-1].split(",")[1]}')
            o.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="{col}" stroke-width="2.4"/>')
        else:
            for k, (tt, vv) in enumerate(ch):
                xa = sx(tt)
                xb = sx(ch[k + 1][0]) if k + 1 < len(ch) else X1
                d = 5 if xb - xa > 12 else 0
                o.append(f'<polygon points="{xa:.1f},{(yh+yl)/2} {xa+d:.1f},{yh} {xb-d:.1f},{yh} {xb:.1f},{(yh+yl)/2} {xb-d:.1f},{yl} {xa+d:.1f},{yl}" fill="{C["panel"]}" stroke="{col}" stroke-width="1.6"/>')
                txt = fmt_val(vv, r.get('fmt', 'hex'), r.get('width'))
                if xb - xa > 9 * len(txt) + 8:
                    o.append(f'<text x="{(xa+xb)/2:.1f}" y="{(yh+yl)/2+6}" font-size="15" font-weight="bold" fill="{col}" text-anchor="middle">{html.escape(txt)}</text>')
    for m in panel.get('markers', []):
        x = sx(m['t'])
        mc = C.get(m.get('color', 'red'), m.get('color'))
        o.append(f'<line x1="{x:.1f}" y1="{top-14}" x2="{x:.1f}" y2="{top+rh*len(rows)}" stroke="{mc}" stroke-width="2" stroke-dasharray="6,4"/>')
        anchor = m.get('anchor', 'start')
        dx = 6 if anchor == 'start' else -6
        yy = top - 18 - 18 * m.get('lane', 0)
        o.append(f'<text x="{x+dx:.1f}" y="{yy}" font-size="15" font-weight="bold" fill="{mc}" text-anchor="{anchor}">{html.escape(m["text"])}</text>')
    yb = top + rh * len(rows) + 52
    for k, line in enumerate(panel.get('caption', [])):
        o.append(f'<text x="40" y="{yb + 24*k}" font-size="16" fill="{C["text"]}">{html.escape(line)}</text>')
    o.append('</svg>')
    svg = '\n'.join(o)
    base = os.path.splitext(out_png)[0]
    open(base + '.svg', 'w', encoding='utf-8').write(svg)
    with tempfile.TemporaryDirectory() as d:
        hp = os.path.join(d, 'p.html')
        open(hp, 'w').write(f'<html><body style="margin:0">{svg}</body></html>')
        subprocess.run(['google-chrome', '--headless=new', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
                        '--force-device-scale-factor=2', f'--window-size={W},{H}', f'--screenshot={out_png}',
                        'file://' + hp], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
