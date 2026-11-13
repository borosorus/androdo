#!/usr/bin/env python3
"""Generate standalone Androdo window studies. All data and drawings are fictional.

No app modules, preferences, phone transport, repository access or network requests.
Optional PNG rendering uses an existing rsvg-convert installation.
"""
from __future__ import annotations

import argparse
from html import escape
import json
from pathlib import Path
import shutil
import subprocess

LIGHT = dict(bg="#f8f9fb", chrome="#f0f2f5", sidebar="#edf1f5", paper="#ffffff",
             text="#202834", secondary="#626e7d", muted="#84909d", line="#dce2e9",
             blue="#315fbd", bluewash="#dfe9fa", teal="#287779", copper="#9f633d",
             green="#317453", white="#ffffff", pill="#eef2f7", select="#dce8fb")
DARK = dict(bg="#1b2027", chrome="#252b34", sidebar="#242c35", paper="#252c35",
            text="#e9edf3", secondary="#acb7c5", muted="#8794a5", line="#3a4451",
            blue="#9bbfff", bluewash="#2d405c", teal="#85c9c7", copper="#ddb28b",
            green="#9bd6b4", white="#ffffff", pill="#303a47", select="#304969")


def rect(x, y, w, h, fill, radius=0, stroke="none", extra=""):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" stroke="{stroke}" {extra}/>'


def text(x, y, value, size=13, fill="#202834", weight=400, extra=""):
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" {extra}>{escape(value)}</text>'


def glyph(name, x, y, color, size=20):
    paths = {
        "overview": '<rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M10 5h4M10 19h4"/>',
        "files": '<path d="M3 7V5a1 1 0 0 1 1-1h6l2 3h8a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z"/>',
        "archive": '<rect x="3" y="7" width="18" height="14" rx="2"/><path d="M2 3h20v4H2zM9 11h6"/>',
        "activity": '<path d="M4 8a9 9 0 1 1-1 7M4 3v5h5M12 7v6l4 2"/>',
        "drive": '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M3 14h18M16 17h2"/>',
        "refresh": '<path d="M19 8a8 8 0 1 0 1 8M20 3v6h-6"/>',
        "settings": '<path d="m9 3-1 3-3 1 1 3-2 2 2 2-1 3 3 1 1 3h4l1-3 3-1-1-3 2-2-2-2 1-3-3-1-1-3Z"/><circle cx="11" cy="12" r="3"/>',
        "document": '<path d="M6 2h8l5 5v15H6zM14 2v6h5M9 12h7M9 16h7"/>',
        "check": '<path d="m5 12 5 5L20 6"/>',
        "chevron": '<path d="m9 6 6 6-6 6"/>',
        "down": '<path d="m6 9 6 6 6-6"/>',
        "sidebar": '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M10 4v16"/>',
        "usb": '<path d="M12 21V3m-3 3 3-3 3 3M12 15l-6-4V7m6 5 6-3V5"/><circle cx="6" cy="5" r="2"/><path d="M16 2h4v3h-4z"/>',
        "warning": '<path d="m12 3 10 18H2ZM12 9v5M12 17v.5"/>',
    }
    return (f'<g transform="translate({x} {y}) scale({size / 24})" fill="none" stroke="{color}" '
            f'stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">{paths[name]}</g>')


def logo(kind, x, y, size=26, dock=False, dark=False):
    """Same mark geometry is used for window branding and Dock treatments."""
    content = ''
    if dock:
        content += rect(0, 0, 100, 100, "url(#brand)", 23)
        content += '<g transform="translate(13 13) scale(.74)">'
    if kind == "fold":
        # A folded archive spine: distinctive silhouette, no circular sync arrows.
        content += '<path d="M12 81 39 20Q43 11 51 11H61L89 81H68L59 58H38L29 81ZM45 41H53L49 29Z" fill="' + ("#fff" if dock else ("url(#brand-dark)" if dark else "url(#brand)")) + '" fill-rule="evenodd"/>'
        content += '<path d="M38 58h21l9 23H51Z" fill="#c48a60"/>'
    else:
        content += '<rect x="18" y="10" width="45" height="72" rx="11" fill="none" stroke="' + ("#fff" if dock else ("#83c9cc" if dark else "#377e9a")) + '" stroke-width="8"/>'
        content += '<path d="M35 20h12" stroke="' + ("#fff" if dock else ("#83c9cc" if dark else "#377e9a")) + '" stroke-width="3" stroke-linecap="round"/>'
        content += '<rect x="44" y="56" width="45" height="32" rx="6" fill="' + ("#fff" if dock else ("#83c9cc" if dark else "#377e9a")) + '"/>'
        content += '<path d="M58 65h17" stroke="#c48a60" stroke-width="5" stroke-linecap="round"/>'
    if dock:
        content += '</g>'
    return f'<g transform="translate({x} {y}) scale({size / 100})">{content}</g>'


def button(x, y, label, p, width=None, primary=False, icon=None, disabled=False):
    width = width or (len(label) * 7 + 30)
    result = rect(x, y, width, 34, p["pill"] if disabled else ("#315fbd" if primary else p["paper"]), 9,
                  "none" if primary else p["line"])
    if icon:
        result += glyph(icon, x + 11, y + 8, "#fff" if primary else p["secondary"], 18)
    result += text(x + (width / 2 if not icon else 35), y + 22, label, 13,
                   p["muted"] if disabled else ("#ffffff" if primary else p["text"]), 500,
                   'text-anchor="middle"' if not icon else '')
    return result


def pill(x, y, label, p, color=None, width=86):
    color = color or p["green"]
    return (rect(x, y, width, 24, p["pill"], 12)
            + glyph("check", x + 8, y + 5, color, 14)
            + text(x + 29, y + 16, label, 11, color, 500))


def phone(x, y, p, connected=True):
    return ('<g>' + rect(x, y, 60, 104, p["paper"], 13, p["line"])
            + rect(x + 6, y + 7, 48, 89, p["bluewash"], 8)
            + rect(x + 23, y + 10, 14, 3, p["muted"], 2)
            + glyph("usb", x + 19, y + 42, p["teal"] if connected else p["muted"], 24)
            + '</g>')


def setting_rows(x, y, width, p, first=False, busy=False):
    out = rect(x, y, width, 152, p["paper"], 13, p["line"])
    for row in range(2):
        ry = y + row * 76
        color = p["blue"] if row == 0 else p["teal"]
        out += rect(x + 18, ry + 20, 36, 36, p["pill"], 9)
        out += glyph("drive" if row == 0 else "files", x + 25, ry + 27, color, 22)
        out += text(x + 68, ry + 29, "Back up to" if row == 0 else "Included files", 12, p["secondary"], 500)
        if first:
            value = "Choose a folder on this Mac or an external drive" if row == 0 else "Choose files after connecting your phone"
            out += text(x + 68, ry + 51, value if width > 600 else ("Choose a backup folder" if row == 0 else "Available after connection"), 13, p["secondary"])
        elif row == 0:
            out += text(x + 68, ry + 51, "Field Drive / Android Backups", 14, p["text"], 500)
        else:
            out += glyph("files", x + 68, ry + 38, p["blue"], 17)
            out += text(x + 91, ry + 51, "Pictures", 13, p["text"])
            out += glyph("document", x + 164, ry + 38, p["copper"], 17)
            out += text(x + 187, ry + 51, "Documents", 13, p["text"])
        if not (first and row == 1):
            out += button(x + width - 110, ry + 22, "Choose…" if first or row else "Change…", p, 91, disabled=busy)
    out += f'<path d="M{x + 68} {y + 76}H{x + width}" stroke="{p["line"]}"/>'
    return out


def overview(x, width, height, p, state):
    first = state == "first-use"
    y = 110 if height >= 700 else 94
    compact = width < 660
    out = phone(x + 2, y + 1, p, not first)
    out += text(x + 86, y + 28, "Your Android" if first else "Pixel 9", 27, p["text"], 600)
    out += f'<circle cx="{x + 90}" cy="{y + 51}" r="3.2" fill="{p["muted"] if first else p["teal"]}"/>'
    out += text(x + 101, y + 56, "Connection setup needed" if first else "Connected by USB", 12, p["secondary"])
    if state == "progress":
        out += text(x + width - 10, y + 31, "Backing up…", 13, p["secondary"], 500, 'text-anchor="end"')
    else:
        out += button(x + width - (190 if first else 136), y + 9,
                      "Set Up Connection…" if first else "Back Up…", p, 190 if first else 136, True)
    if first:
        out += text(x + 86, y + 84, "ADB is needed for USB access.", 13, p["secondary"])
        out += text(x + 86, y + 104, "We’ll walk you through it.", 13, p["secondary"])
    else:
        out += text(x + 86, y + 86, "Latest complete backup", 11, p["secondary"], 500)
        out += text(x + 86, y + 110, "Today, 10:42", 18, p["text"], 500)
        out += pill(x + 226, y + 92, "Complete", p)
        out += text(x + 86, y + 132, "128 files · 842 MB", 12, p["secondary"])
    row_y = y + 166
    out += setting_rows(x, row_y, width, p, first, busy=state == "progress")
    history_y = row_y + 194
    out += glyph("archive", x + 4, history_y - 16, p["copper"], 20)
    out += text(x + 34, history_y, "Already have backups?" if first else "3 restore points", 13, p["text"], 500)
    out += button(x + width - (188 if first else 161), history_y - 23,
                  "Open Backup Folder…" if first else "Browse Backups", p, 188 if first else 161)
    if not compact and not first:
        out += text(x + 34, history_y + 21, "2 complete · 1 incomplete", 11, p["secondary"])
    return out


def library(x, width, height, p):
    list_w = 221 if width > 700 else 190
    out = rect(x, 68, list_w, height - 68, p["paper"])
    out += f'<path d="M{x + list_w} 68V{height}" stroke="{p["line"]}"/>'
    out += text(x + 20, 106, "Pixel 9", 14, p["text"], 600) + glyph("down", x + list_w - 37, 91, p["secondary"], 16)
    out += text(x + 20, 130, "Field Drive", 11, p["secondary"])
    out += text(x + 20, 170, "RESTORE POINTS", 10, p["secondary"], 600, 'letter-spacing="1"')
    rows = [("Today, 10:42", "128 files · 842 MB", "Complete"),
            ("Yesterday, 18:09", "125 files · 826 MB", "Incomplete · 3 skipped"),
            ("8 November, 09:15", "118 files · 790 MB", "Complete")]
    for i, (date, summary, status) in enumerate(rows):
        y = 188 + i * 100
        if i == 0:
            out += rect(x + 9, y, list_w - 18, 87, p["select"], 9)
        out += glyph("archive", x + 20, y + 13, p["copper"], 17)
        out += text(x + 46, y + 26, date, 12, p["text"], 600)
        out += text(x + 20, y + 49, summary, 11, p["secondary"])
        out += glyph("warning" if i == 1 else "check", x + 20, y + 61, p["copper"] if i == 1 else p["green"], 13)
        out += text(x + 39, y + 73, status, 10, p["copper"] if i == 1 else p["secondary"])
    right = x + list_w
    inner = right + 26
    out += glyph("archive", inner, 98, p["copper"], 29)
    out += text(inner + 43, 114, "Today, 10:42", 22, p["text"], 600)
    out += text(inner + 43, 137, "128 files · 842 MB", 12, p["secondary"])
    out += button(inner, 165, "Restore to Phone…", p, 163, True)
    out += button(inner + 174, 165, "Export…", p, 94)
    table_y = 234
    out += text(inner, table_y, "Name", 11, p["secondary"], 500)
    out += text(x + width - 26, table_y, "Size", 11, p["secondary"], 500, 'text-anchor="end"')
    out += f'<path d="M{inner} {table_y + 12}H{x + width - 22}" stroke="{p["line"]}"/>'
    rows = [("Pictures", "816 MB", "files", 0), ("Camera", "748 MB", "files", 1),
            ("Screenshots", "68 MB", "files", 1), ("Documents", "26 MB", "files", 0)]
    for i, (name, size, symbol, indent) in enumerate(rows):
        y = table_y + 29 + 43 * i
        left = inner + indent * 19
        out += rect(left, y, 14, 14, "#315fbd", 3) + glyph("check", left + 1, y + 1, "#fff", 12)
        out += glyph(symbol, left + 25, y - 2, p["blue"], 20)
        out += text(left + 55, y + 12, name, 13, p["text"], 500 if not indent else 400)
        out += text(x + width - 26, y + 12, size, 12, p["secondary"], 400, 'text-anchor="end"')
    out += text(inner, height - 31, "All 128 files selected", 11, p["secondary"])
    return out


def window(kind="fold", state="overview", theme="light", size="standard", collapsed=False):
    p = DARK if theme == "dark" else LIGHT
    w, h = (900, 600) if size == "compact" else (1120, 720)
    side = 0 if collapsed else (210 if size == "compact" else 230)
    margin = 30
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w + margin * 2}" height="{h + margin * 2}" viewBox="0 0 {w + margin * 2} {h + margin * 2}" role="img">',
           f'<title>Androdo — {"folded A" if kind == "fold" else "phone/archive"} — {state} — {theme}</title>',
           '<desc>Static full-window design study using fictional names, dates and counts. Controls in this illustration do not perform operations.</desc>',
           '<defs><linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#315fbd"/><stop offset="1" stop-color="#2a8589"/></linearGradient>',
           '<linearGradient id="brand-dark" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#9bbfff"/><stop offset="1" stop-color="#85c9c7"/></linearGradient>',
           '<filter id="shadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="9" stdDeviation="12" flood-color="#111b29" flood-opacity=".15"/></filter>',
           f'<clipPath id="window"><rect width="{w}" height="{h}" rx="14"/></clipPath></defs>',
           f'<g font-family="Helvetica Neue, Arial, sans-serif" transform="translate({margin} {margin})">',
           rect(0, 0, w, h, p["bg"], 14, p["line"], 'filter="url(#shadow)"'), '<g clip-path="url(#window)">']
    if side:
        out += [rect(0, 0, side, h, p["sidebar"]), f'<path d="M{side} 68V{h}" stroke="{p["line"]}"/>']
    out += [rect(0, 0, w, 68, p["chrome"])]
    for i, color in enumerate(["#ec6b62", "#e8b84b", "#63bb64"]):
        out += [f'<circle cx="{23 + i * 19}" cy="32" r="5.4" fill="{color}"/>']
    out += [glyph("sidebar", 87, 22, p["secondary"], 20), logo(kind, 120, 21, 25, dark=theme == "dark"),
            text(151, 39, "Androdo", 16, p["text"], 600)]
    # Brand stays in one place when the sidebar collapses; page context follows it.
    title_x = max(side + 28, 260)
    out += [text(title_x, 30, "Backups" if state == "backups" else "Overview", 13, p["text"], 600),
            text(title_x, 49, "Getting started" if state == "first-use" else "Pixel 9", 11, p["secondary"]),
            glyph("refresh", w - 45, 23, p["muted"] if state in ("first-use", "progress") else p["secondary"], 20)]
    if side:
        for i, (name, symbol, color) in enumerate([("Overview", "overview", p["blue"]), ("Backups", "archive", p["copper"]),
                                                   ("Files", "files", p["blue"]), ("Activity", "activity", p["teal"])]):
            y = 93 + i * 39
            selected = (state == "backups" and name == "Backups") or (state != "backups" and name == "Overview")
            if selected:
                out += [rect(10, y - 5, side - 20, 33, p["select"], 7)]
            out += [glyph(symbol, 23, y + 1, color, 19), text(54, y + 16, name, 13, p["text"], 500 if selected else 400)]
        out += [text(23, 293, "DEVICES", 10, p["secondary"], 600, 'letter-spacing="1"')]
        if state == "first-use":
            out += [text(24, 322, "No phone connected", 12, p["secondary"])]
        else:
            out += [glyph("overview", 23, 311, p["teal"], 21), text(54, 326, "Pixel 9", 12, p["text"], 500),
                    f'<circle cx="59" cy="343" r="2.5" fill="{p["teal"]}"/>', text(68, 347, "USB connected", 10, p["secondary"])]
        out += [glyph("settings", 24, h - 43, p["secondary"], 18), text(54, h - 29, "Settings", 12, p["secondary"])]
    if state == "backups":
        out += [library(side, w - side, h, p)]
    else:
        inset = 28 if size == "compact" else 42
        out += [overview(side + inset, w - side - inset * 2, h, p, state)]
    if state == "progress":
        footer_x = side + 24
        out += [rect(side, h - 75, w - side, 75, p["chrome"]),
                f'<path d="M{side} {h - 75}H{w}" stroke="{p["line"]}"/>',
                text(footer_x, h - 49, "Backing up Pixel 9", 12, p["text"], 600),
                text(footer_x + 173, h - 49, "82 of 128 files · 512 MB copied", 11, p["secondary"]),
                rect(footer_x, h - 31, w - side - 135, 4, p["line"], 2),
                rect(footer_x, h - 31, (w - side - 135) * .64, 4, "#315fbd", 2),
                button(w - 95, h - 57, "Cancel", p, 72)]
    out += ['</g>', rect(0, 0, w, h, "none", 14, p["line"]), '</g></svg>']
    return ''.join(out)


def identity_board(kind, theme):
    p = DARK if theme == "dark" else LIGHT
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="170" viewBox="0 0 1120 170" role="img">',
           '<title>Androdo identity applications: app icon, wordmark, and small glyphs</title>',
           '<defs><linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#315fbd"/><stop offset="1" stop-color="#2a8589"/></linearGradient>',
           '<linearGradient id="brand-dark" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#9bbfff"/><stop offset="1" stop-color="#85c9c7"/></linearGradient></defs>',
           '<g font-family="Helvetica Neue, Arial, sans-serif">',
           rect(0, 0, 1120, 170, p['bg'], 12),
           logo(kind, 27, 20, 100, dock=True),
           text(27, 146, "APP ICON", 10, p['secondary'], 500),
           logo(kind, 190, 44, 45, dark=theme == 'dark'),
           text(250, 80, "Androdo", 34, p['text'], 600),
           text(190, 146, "WINDOW IDENTITY", 10, p['secondary'], 500),
           logo(kind, 649, 57, 16, dark=theme == 'dark'),
           logo(kind, 700, 53, 24, dark=theme == 'dark'),
           text(648, 146, "16 / 24 PX", 10, p['secondary'], 500),
           '</g></svg>']
    return ''.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('dist/androdo-window-study'))
    parser.add_argument('--render-png', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    illustrations = {}
    for kind in ('fold', 'phone'):
        for state in ('overview', 'first-use', 'backups', 'progress'):
            for theme in ('light', 'dark'):
                for layout in ('standard', 'compact', 'collapsed'):
                    key = '-'.join((kind, state, theme, layout))
                    illustrations[key] = window(kind, state, theme, 'compact' if layout == 'compact' else 'standard', layout == 'collapsed')
    for kind in ('fold', 'phone'):
        for theme in ('light', 'dark'):
            illustrations[f'identity-{kind}-{theme}'] = identity_board(kind, theme)
    # SVG exports are useful independently of the comparison page.
    exports = ('fold-overview-light-standard', 'phone-overview-light-standard', 'fold-overview-dark-standard',
               'fold-first-use-light-standard', 'fold-backups-light-standard', 'fold-progress-light-compact',
               'fold-overview-light-collapsed', 'identity-fold-light', 'identity-phone-light')
    for key in exports:
        path = args.output / f'{key}.svg'
        path.write_text(illustrations[key], encoding='utf-8')
        if args.render_png:
            renderer = shutil.which('rsvg-convert')
            if not renderer:
                parser.error('--render-png requires an existing rsvg-convert installation')
            subprocess.run([renderer, '-o', str(path.with_suffix('.png')), str(path)], check=True)
    template = Path(__file__).with_name('window_study.html').read_text(encoding='utf-8')
    (args.output / 'index.html').write_text(template.replace('/*ILLUSTRATIONS*/', json.dumps(illustrations)), encoding='utf-8')
    print(args.output / 'index.html')


if __name__ == '__main__':
    main()
