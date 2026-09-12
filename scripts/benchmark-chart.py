#!/usr/bin/env python3
"""The leaderboard as a picture: failures ranked, price at the end of each bar."""

ROWS = [  # engine, failure %, price label, kind
    ("Claude Opus 5",        0,  "$3.59", "cloud"),
    ("GPT-5.6 Sol",          0,  "$3.76", "cloud"),
    ("GPT-5.6 Terra",        3,  "$1.92", "cloud"),
    ("Claude Haiku 4.5",     4,  "$1.00", "cloud"),
    ("GPT-5.6 Luna",         5,  "$0.21", "pick"),
    ("Claude Sonnet 5",      5,  "$2.74", "cloud"),
    ("GPT-4o Mini",         11,  "$0.12", "cloud"),
    ("GPT-4.1 Mini",        14,  "$0.32", "cloud"),
    ("Gemma 4 E2B",         35,  "free",  "device"),
    ("Apple Intelligence",  53,  "free",  "device"),
    ("Fillers only, no LLM",57,  "free",  "none"),
    ("No cleanup at all",   70,  "free",  "none"),
]

THEMES = {
    "light": dict(ink="#19202B", muted="#5A6475", rule="#D9DEE6", accent="#1F5FD6",
                  soft="#9DB8EE", warm="#C23B26", pale="#E7B9B1"),
    "dark":  dict(ink="#E5E9F0", muted="#98A2B3", rule="#283040", accent="#7AA2FF",
                  soft="#3A5488", warm="#F08472", pale="#6E3B33"),
}

LEFT, BAR_X, SCALE = 8, 196, 6.1          # 70% -> 427px
ROW_H, TOP = 27, 62
PRICE_X = 752                              # prices line up in their own column

def svg(theme):
    c, p = THEMES[theme], []
    add = p.append
    height = TOP + len(ROWS) * ROW_H + 34
    add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 760 {height}" width="760" height="{height}" '
        f'font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12.5">')
    add('<title>Takes with a hard failure, by cleanup engine, with the price per thousand takes</title>')
    add(f'<text x="{LEFT}" y="18" fill="{c["ink"]}" font-family="system-ui, -apple-system, sans-serif" '
        f'font-size="13" font-weight="600">Takes with a hard failure</text>')
    add(f'<text x="752" y="18" text-anchor="end" fill="{c["muted"]}" font-family="system-ui, -apple-system, sans-serif" '
        f'font-size="12">125 dictations · price per 1,000 takes</text>')
    # grid
    for pct in (0, 20, 40, 60):
        gx = BAR_X + pct * SCALE
        add(f'<line x1="{gx:.0f}" y1="{TOP-14}" x2="{gx:.0f}" y2="{TOP + len(ROWS)*ROW_H - 6}" '
            f'stroke="{c["rule"]}" stroke-width="1"/>')
        add(f'<text x="{gx:.0f}" y="{TOP-20}" text-anchor="middle" fill="{c["muted"]}" font-size="11">{pct}%</text>')
    for i, (name, pct, price, kind) in enumerate(ROWS):
        y = TOP + i * ROW_H
        fill = {"cloud": c["accent"], "pick": c["accent"], "device": c["warm"], "none": c["pale"]}[kind]
        weight = ' font-weight="700"' if kind == "pick" else ""
        add(f'<text x="{BAR_X-12}" y="{y+4}" text-anchor="end" fill="{c["ink"]}"{weight}>{name}</text>')
        width = max(pct * SCALE, 2.5)
        add(f'<rect x="{BAR_X}" y="{y-8}" width="{width:.1f}" height="15" rx="1.5" fill="{fill}" '
            f'{"stroke=\'"+c["accent"]+"\' stroke-width=\'2\'" if kind == "pick" else ""}/>')
        add(f'<text x="{BAR_X + width + 9:.0f}" y="{y+4}" fill="{c["ink"]}"{weight}>{pct}%</text>')
        add(f'<text x="{PRICE_X}" y="{y+4}" text-anchor="end" fill="{c["muted"]}"{weight}>{price}</text>')
        if kind == "pick":
            add(f'<text x="{BAR_X + width + 52:.0f}" y="{y+4}" fill="{c["accent"]}" font-weight="700">← the default</text>')
    footer = TOP + len(ROWS) * ROW_H + 20
    add(f'<text x="{LEFT}" y="{footer}" fill="{c["muted"]}" font-family="system-ui, -apple-system, sans-serif" font-size="11.5">'
        f'Blue: cloud models. Red: on-device. Pale: no model at all. One run per case, September 2026.</text>')
    add('</svg>')
    return "\n".join(p) + "\n"

import pathlib
for theme in THEMES:
    out = pathlib.Path(f"assets/polish-benchmark-{theme}.svg")
    out.write_text(svg(theme))
    print(out, out.stat().st_size, "bytes")
