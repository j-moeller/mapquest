"""Shared pieces of the App Store mockups (Tools/screenshots): data from the app's
resources, the map view's projection, iOS-like chrome (status bar, materials,
lists) and icons (Material Symbols as a stand-in for SF Symbols)."""
import json
import math
import os
import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parents[2]
RES = REPO / "App/MapQuest/Resources"
SHOTS = pathlib.Path(os.environ.get("MQ_SHOTS_DIR", REPO / "build-screenshots")).resolve()

SIGHTS = {s["id"]: s for s in json.loads((RES / "Berlin/berlin-sights.json").read_text())["sights"]}
INFO = json.loads((RES / "Berlin/berlin-sight-info.json").read_text())["entries"]
HISTORY = json.loads((RES / "Berlin/berlin-sight-history.json").read_text())["entries"]
HISTORY_DE = json.loads((RES / "Berlin/berlin-sight-history-de.json").read_text())["entries"]
ACHIEVEMENTS = {a["id"]: a for a in json.loads((RES / "Berlin/berlin-achievements.json").read_text())["achievements"]}
STATIONS = json.loads((RES / "Berlin/berlin-stations.json").read_text())
REMEMBRANCE = json.loads((RES / "Berlin/berlin-remembrance.json").read_text())

def strings(name):
    table = {}
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', (RES / f"de.lproj/{name}").read_text(), re.M):
        table[m.group(1).replace('\\"', '"')] = m.group(2).replace('\\"', '"')
    return table

DE = {**strings("Localizable.strings"), **strings("Capture.strings")}

def name(sight_id, lang="en"):
    s = SIGHTS[sight_id]
    return s.get("nameEn", s["name"]) if lang == "en" else s["name"]

def other_name(sight_id):
    s = SIGHTS[sight_id]
    return s["name"] if s.get("nameEn") else None

def frame(lat, lon):
    """Pixels of zoom-15 tiles of 512 pixels (the frame the map is exported in)."""
    n = 2 ** 15 * 512
    return (lon + 180) / 360 * n, (1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n

def unframe(fx, fy):
    n = 2 ** 15 * 512
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * fy / n)))), fx / n * 360 - 180

# The main map view (FogMapView): Brandenburger Tor to Bebelplatz, 430 × 932 points.
VIEW = dict(lat=52.5160, lon=13.3870, zoom=14.75)
K = 2 * 2 ** (15 - VIEW["zoom"])  # frame pixels per screen point
_cx, _cy = frame(VIEW["lat"], VIEW["lon"])
VIEW["vx"], VIEW["vy"] = round(_cx - 430 * K / 2), round(_cy - 932 * K / 2)

def export_bounds(margin=80):
    """The frame rectangle the map is exported for (the view and a margin for the blur)."""
    return (VIEW["vx"] - margin, VIEW["vy"] - margin, round(VIEW["vx"] + 430 * K + margin), round(VIEW["vy"] + 932 * K + margin))

def screen(lat, lon):
    fx, fy = frame(lat, lon)
    return (fx - VIEW["vx"]) / K, (fy - VIEW["vy"]) / K

def _pieces():
    pieces = []
    path = SHOTS / "discovered.d"
    if not path.exists():
        return pieces
    for line in path.read_text().split("\n"):
        rings = []
        for ring in re.findall(r"M([^MZ]+)Z", line):
            pts = [tuple(map(float, p.split())) for p in ring.split("L")]
            rings.append(pts)
        if rings:
            pieces.append(rings)
    return pieces

PIECES = _pieces()

def discovered(lat, lon):
    x, y = frame(lat, lon)
    for rings in PIECES:
        inside = False
        for ring in rings:
            for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
                if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
                    inside = not inside
        if inside:
            return True
    return False

ICONS = {  # SF Symbols of the app → Material Symbols (the stand-in here)
    "landmark": "star", "museum": "account_balance", "palace": "castle", "church": "church", "viewpoint": "landscape",
    "memorial": "rectangle", "park": "park", "square": "grid_view", "culture": "theater_comedy", "monument": "flag",
    "zoo": "pets", "bridge": "water", "stadium": "stadium", "fountain": "water_drop", "market": "shopping_basket",
    "government": "domain", "cemetery": "rectangle", "club": "headphones",
}
SYMBOLS = {
    "figure.walk": "directions_walk", "shoeprints.fill": "footprint", "map.fill": "map", "star.circle.fill": "stars",
    "books.vertical.fill": "auto_stories", "trophy.fill": "emoji_events", "bell.fill": "notifications", "drop.fill": "water_drop",
    "basket.fill": "shopping_basket", "building.columns.fill": "account_balance", "theatermasks.fill": "theater_comedy",
    "headphones": "headphones", "crown.fill": "crown", "crown": "crown", "binoculars.fill": "landscape", "leaf.fill": "eco",
    "building.2.fill": "domain", "tree.fill": "park", "sparkles": "auto_awesome", "square.split.2x1.fill": "splitscreen_left",
    "pencil.and.ruler.fill": "architecture", "mappin.and.ellipse": "location_on", "tram.fill": "tram",
    "flag.fill": "flag", "building.columns": "account_balance", "square.grid.2x2.fill": "grid_view",
    "building.columns.circle.fill": "account_balance", "globe.europe.africa.fill": "public", "seal.fill": "verified",
}

def stone(size, color="rgba(255,255,255,0.9)"):
    """The plain stone of places of remembrance (rectangle.portrait.fill)."""
    return (f'<span style="display:inline-block;width:{size*0.62:.1f}px;height:{size:.1f}px;border-radius:{size*0.12:.1f}px;'
            f'background:{color}"></span>')

def icon(name, size=20, color=None, extra=""):
    if name == "rectangle":
        return stone(size * 0.8, color or "rgba(255,255,255,0.9)")
    style = f"font-size:{size}px;" + (f"color:{color};" if color else "")
    return f'<span class="ms" style="{style}{extra}">{name}</span>'

GOLD = "rgb(255,194,46)"
ORANGE = "#FF9500"
ACCENT = "rgb(245,153,46)"
STONE = "rgb(107,115,125)"
U_BLUE = "#0065AE"
S_GREEN = "#008D4F"

CSS = """
@font-face { font-family: 'MS'; src: url('assets/material-symbols.woff2') format('woff2'); }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { width: 430px; height: 932px; overflow: hidden; font-family: 'Inter', sans-serif; -webkit-font-smoothing: antialiased;
       color: #000; letter-spacing: -0.01em; }
.ms { font-family: 'MS'; font-weight: normal; font-style: normal; line-height: 1; letter-spacing: normal; text-transform: none;
      display: inline-block; white-space: nowrap; direction: ltr; font-feature-settings: 'liga'; -webkit-font-smoothing: antialiased; }
.screen { position: relative; width: 430px; height: 932px; overflow: hidden; }
.status { position: absolute; left: 0; right: 0; top: 0; height: 54px; display: flex; align-items: center; justify-content: space-between;
          padding: 6px 30px 0 52px; font-size: 17px; font-weight: 600; z-index: 50; }
.status.light { color: #fff; } .status.dark { color: #000; }
.status .right { display: flex; gap: 6px; align-items: center; }
.material { background: rgba(250,250,252,0.78); backdrop-filter: blur(22px) saturate(1.6); -webkit-backdrop-filter: blur(22px) saturate(1.6); }
.secondary { color: rgba(60,60,67,0.6); }
.caption { font-size: 12px; } .caption2 { font-size: 11px; } .sub { font-size: 15px; } .body { font-size: 17px; }
.headline { font-size: 17px; font-weight: 600; } .title3 { font-size: 20px; } .title2 { font-size: 22px; font-weight: 700; }
/* Sheets and grouped lists */
.backdrop { position: absolute; inset: 0; background: #000; }
.under { position: absolute; left: 10px; right: 10px; top: 46px; height: 60px; border-radius: 12px 12px 0 0; overflow: hidden; opacity: 0.55; }
.sheet { position: absolute; left: 0; right: 0; top: 58px; bottom: 0; background: #F2F2F7; border-radius: 12px 12px 0 0; overflow: hidden; }
.nav { height: 52px; display: flex; align-items: center; justify-content: center; position: relative; font-size: 17px; font-weight: 600; }
.nav .done { position: absolute; right: 18px; color: rgb(245,153,46); font-weight: 600; }
.nav .back { position: absolute; left: 10px; color: rgb(245,153,46); font-weight: 400; display: flex; align-items: center; }
.list { padding: 0 16px; }
.section { background: #fff; border-radius: 10px; overflow: hidden; margin-bottom: 18px; }
.section-header { font-size: 13px; color: rgba(60,60,67,0.6); text-transform: uppercase; padding: 0 16px 6px; letter-spacing: 0; }
.section-footer { font-size: 13px; color: rgba(60,60,67,0.6); padding: 6px 16px 0; margin-top: -12px; margin-bottom: 18px; line-height: 1.3; }
.row { display: flex; align-items: center; gap: 12px; padding: 9px 16px; min-height: 44px; position: relative; }
.row + .row::before { content: ""; position: absolute; top: 0; left: 62px; right: 0; height: 0.5px; background: rgba(60,60,67,0.29); }
.row.plain + .row.plain::before { left: 16px; }
.chev { color: rgba(60,60,67,0.3); font-size: 22px; margin-left: auto; }
.seg { display: flex; background: rgba(118,118,128,0.12); border-radius: 9px; padding: 2px; font-size: 13px; font-weight: 500; }
.seg div { flex: 1; text-align: center; padding: 6px 2px; border-radius: 7px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.seg .on { background: #fff; box-shadow: 0 3px 8px rgba(0,0,0,0.12), 0 3px 1px rgba(0,0,0,0.04); font-weight: 600; }
.progress { height: 4px; border-radius: 2px; background: rgba(120,120,128,0.2); overflow: hidden; }
.progress div { height: 100%; background: #FF9500; border-radius: 2px; }
/* Map pins */
.pin { position: absolute; width: 30px; height: 30px; margin: -15px 0 0 -15px; border-radius: 50%; border: 2px solid #fff;
       box-shadow: 0 0 3px rgba(0,0,0,0.45); display: flex; align-items: center; justify-content: center; color: #fff; }
.pin .ms { font-size: 17px; }
.pin.captured { background: rgb(255,194,46); } .pin.discovered { background: #FF9500; }
.pin.remembrance { width: 24px; height: 24px; margin: -12px 0 0 -12px; background: rgb(107,115,125); }
.pin.remembrance .ms { font-size: 12px; opacity: 0.9; }
.pin .cam { position: absolute; right: -6px; top: -5px; width: 15px; height: 15px; border-radius: 50%; background: #fff;
            display: flex; align-items: center; justify-content: center; }
.pin .cam .ms { font-size: 10px; color: #FF9500; }
.station { position: absolute; width: 17px; height: 17px; margin: -8.5px 0 0 -8.5px; border: 1.5px solid #fff; color: #fff;
           font-size: 11.5px; font-weight: 800; display: flex; align-items: center; justify-content: center; box-shadow: 0 0 2px rgba(0,0,0,0.4); }
.station.u { background: #0065AE; border-radius: 3px; } .station.s { background: #008D4F; border-radius: 50%; }
.badge { flex: none; border-radius: 50%; display: flex; align-items: center; justify-content: center; position: relative; }
"""

STATUS_RIGHT = """<svg width="18" height="12" viewBox="0 0 18 12"><rect x="0" y="8" width="3" height="4" rx="1" fill="currentColor"/><rect x="5" y="5.5" width="3" height="6.5" rx="1" fill="currentColor"/><rect x="10" y="3" width="3" height="9" rx="1" fill="currentColor"/><rect x="15" y="0" width="3" height="12" rx="1" fill="currentColor"/></svg>
<svg width="16" height="12" viewBox="0 0 16 12"><path d="M8 2.2c2.4 0 4.6.9 6.2 2.5l1.2-1.2A10.4 10.4 0 0 0 8 .5 10.4 10.4 0 0 0 .6 3.5l1.2 1.2A8.7 8.7 0 0 1 8 2.2zm0 3.4c1.5 0 2.8.6 3.8 1.5l1.2-1.2A7.1 7.1 0 0 0 8 3.9a7.1 7.1 0 0 0-5 2l1.2 1.2c1-.9 2.3-1.5 3.8-1.5zm0 3.4c.6 0 1.2.2 1.6.6L8 11.2 6.4 9.6c.4-.4 1-.6 1.6-.6z" fill="currentColor"/></svg>
<svg width="27" height="13" viewBox="0 0 27 13"><rect x="0.5" y="0.5" width="23" height="12" rx="3.5" fill="none" stroke="currentColor" opacity="0.4"/><rect x="2" y="2" width="17" height="9" rx="2" fill="currentColor"/><path d="M25 4.5v4c.8-.3 1.3-1.1 1.3-2s-.5-1.7-1.3-2z" fill="currentColor" opacity="0.45"/></svg>"""

def status(tone="dark", time="9:41"):
    return f'<div class="status {tone}"><span>{time}</span><span class="right">{STATUS_RIGHT}</span></div>'

def page(body, title="MapQuest"):
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>{title}</title><style>{CSS}</style></head>
<body>{body}</body></html>"""

def sight_badge(category, state, size=34):
    """SightBadge: filled orange once captured, an orange ring once discovered, grey otherwise; stone for remembrance."""
    sym = ICONS.get(category, "star")
    if category in ("memorial", "cemetery"):
        return (f'<div class="badge" style="width:{size}px;height:{size}px;background:{STONE}">'
                f'{icon(sym, size*0.38, "rgba(255,255,255,0.9)")}</div>')
    if state == "captured":
        return f'<div class="badge" style="width:{size}px;height:{size}px;background:{ORANGE}">{icon(sym, size*0.45, "#fff")}</div>'
    if state == "discovered":
        return (f'<div class="badge" style="width:{size}px;height:{size}px;background:rgba(255,149,0,0.15);'
                f'box-shadow: inset 0 0 0 {max(1.5, size*0.06):.1f}px {ORANGE}">{icon(sym, size*0.45, ORANGE)}</div>')
    return f'<div class="badge" style="width:{size}px;height:{size}px;background:rgba(60,60,67,0.12)">{icon(sym, size*0.45, "rgba(60,60,67,0.6)")}</div>'

def medal(symbol, fraction, complete, size=44):
    sym = SYMBOLS.get(symbol, "star")
    if complete:
        return (f'<div class="badge" style="width:{size}px;height:{size}px;background:linear-gradient(#FFC22E,#FF9500)">'
                f'{icon(sym, size*0.42, "#fff")}</div>')
    r = size / 2 - size * 0.05 - max(2, size * 0.07) / 2
    c = 2 * math.pi * r
    ring = (f'<svg width="{size}" height="{size}" style="position:absolute;inset:0;transform:rotate(-90deg)">'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.2f}" fill="none" stroke="{ORANGE}" stroke-width="{max(2, size*0.07):.1f}" '
            f'stroke-linecap="round" stroke-dasharray="{c*fraction:.2f} {c:.2f}"/></svg>') if fraction > 0 else ""
    return (f'<div class="badge" style="width:{size}px;height:{size}px;background:rgba(60,60,67,0.09)">{ring}'
            f'{icon(sym, size*0.4, "rgba(60,60,67,0.55)")}</div>')

def line_sign(system, size=22, collected=True):
    shape = f"border-radius:{size/2}px" if system == "S" else f"border-radius:{size*0.18:.1f}px"
    color = S_GREEN if system == "S" else U_BLUE
    return (f'<div class="badge" style="width:{size}px;height:{size}px;{shape};background:{color};opacity:{1 if collected else 0.4};'
            f'color:#fff;font-weight:800;font-size:{size*0.66:.1f}px">{system}</div>')
