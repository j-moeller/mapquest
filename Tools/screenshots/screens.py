"""The nine mockup screens (430 × 932 pt) as HTML from the app's data, and the
App Store page around each (headline, phone frame). The state shown – what is
captured, discovered, collected – is one illustrative afternoon in Mitte."""
import html as H
from common import *

def esc(s):
    return H.escape(s, quote=False)

# ---- The state shown: one afternoon in Mitte (the map's discovered area) ----
CAPTURED = ["konzerthaus", "franzoesischer-dom", "gendarmenmarkt", "bebelplatz", "checkpoint-charlie"]
DISCOVERED = ["brandenburger-tor", "deutscher-dom", "hedwigs-kathedrale", "dhm", "staatsoper", "humboldt-universitaet"]
REMEMBRANCE_PINS = ["neue-wache", "holocaust-mahnmal", "topographie", "dorotheenstaedtischer-friedhof"]
STATIONS_COLLECTED = ["u:brandenburger-tor", "s:brandenburger-tor", "u:unter-den-linden", "u:stadtmitte",
                      "u:kochstrasse-checkpoint-charlie", "s:friedrichstrasse", "s:potsdamer-platz"]
COUNTS = dict(captured=23, discovered=42, game=166, stations=37, all_stations=len(STATIONS["stations"]),
              achievements=12, all_achievements=len(ACHIEVEMENTS))
STATION = {s["id"]: s for s in STATIONS["stations"]}

def map_layer(dim=0.0):
    out = ['<img src="map-fog.png" style="position:absolute;inset:0;width:430px;height:932px">']
    for sid in REMEMBRANCE_PINS:
        s = SIGHTS[sid]; x, y = screen(s["latitude"], s["longitude"])
        out.append(f'<div class="pin remembrance" style="left:{x:.1f}px;top:{y:.1f}px">{icon(ICONS[s["category"]])}</div>')
    for sid in STATIONS_COLLECTED:
        st = STATION[sid]; x, y = screen(st["latitude"], st["longitude"])
        cls = "s" if st["system"] == "S" else "u"
        out.append(f'<div class="station {cls}" style="left:{x:.1f}px;top:{y:.1f}px">{st["system"]}</div>')
    for sid in CAPTURED + DISCOVERED:
        if sid == "gendarmenmarkt":  # under the Konzerthaus and the cathedrals
            continue
        s = SIGHTS[sid]; x, y = screen(s["latitude"], s["longitude"])
        state = "captured" if sid in CAPTURED else "discovered"
        cam = f'<span class="cam">{icon("photo_camera")}</span>' if state == "discovered" else ""
        out.append(f'<div class="pin {state}" style="left:{x:.1f}px;top:{y:.1f}px">{icon(ICONS[s["category"]])}{cam}</div>')
    # The user, on a discovered street west of Gendarmenmarkt.
    out.append('<div style="position:absolute;left:298px;top:563px;width:64px;height:64px;margin:-32px;border-radius:50%;'
               'background:rgba(0,122,255,0.18)"></div><div style="position:absolute;left:298px;top:563px;width:20px;height:20px;'
               'margin:-10px;border-radius:50%;background:#007AFF;border:3px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)"></div>')
    if dim:
        out.append(f'<div style="position:absolute;inset:0;background:rgba(0,0,0,{dim})"></div>')
    return "\n".join(out)

def bottom_bar(captures=COUNTS["captured"], label="captures", tracking="Tracking"):
    return f'''<div style="position:absolute;right:16px;bottom:118px;font-size:9px;color:rgba(60,60,67,.75);padding:2px 5px;border-radius:9px" class="material">OpenFreeMap © OpenMapTiles · Data © OpenStreetMap contributors</div>
<div class="material" style="position:absolute;left:16px;right:16px;bottom:44px;height:64px;border-radius:16px;display:flex;align-items:center;padding:0 14px;gap:12px">
  <div style="position:relative">{icon("emoji_events", 30, GOLD)}<div style="position:absolute;right:-3px;top:-1px;width:9px;height:9px;border-radius:50%;background:#FF3B30"></div></div>
  <div style="display:flex;flex-direction:column;line-height:1.15"><span style="font-size:20px;font-weight:700">{captures}</span><span class="caption secondary">{label}</span></div>
  <div style="margin-left:auto;background:#34C759;color:#fff;border-radius:22px;padding:10px 16px;display:flex;align-items:center;gap:6px;font-size:17px;font-weight:600">{icon("near_me", 19)}{tracking}</div>
</div>'''

def menu_button():
    return f'<div class="material" style="position:absolute;right:16px;top:62px;width:40px;height:40px;border-radius:10px;display:flex;align-items:center;justify-content:center">{icon("menu", 24)}</div>'

def s1_map():
    return page(f'<div class="screen">{map_layer()}{status("light")}{menu_button()}{bottom_bar()}</div>')

def s2_celebration():
    gate = SIGHTS["brandenburger-tor"]
    cy = 300
    sparks = []
    for i in range(22):
        a = i / 22 * 2 * math.pi + (0.12 if i % 2 == 0 else -0.08)
        d = (170 if i % 3 == 0 else 130) * 0.72
        size = 9 if i % 3 == 0 else 6
        col = GOLD if i % 2 == 0 else "#fff"
        sparks.append(f'<div style="position:absolute;left:{215+math.cos(a)*d-size/2:.1f}px;top:{cy+math.sin(a)*d-size/2:.1f}px;width:{size}px;height:{size}px;border-radius:50%;background:{col};opacity:.55"></div>')
    rays = (f'<div style="position:absolute;left:{215-260}px;top:{cy-260}px;width:520px;height:520px;'
            'background:repeating-conic-gradient(from 6deg, rgba(255,194,46,0.55) 0deg 12.86deg, transparent 12.86deg 25.71deg);'
            '-webkit-mask-image:radial-gradient(circle, #000 20px, rgba(0,0,0,0) 260px);mask-image:radial-gradient(circle, #000 20px, rgba(0,0,0,0) 260px)"></div>')
    medallion = (f'<div style="position:absolute;left:{215-64}px;top:{cy-64}px;width:128px;height:128px;border-radius:50%;'
                 'background:linear-gradient(135deg, rgb(255,230,115), rgb(255,194,46), #FF9500);box-shadow:0 0 24px 6px rgba(255,194,46,0.65);'
                 'display:flex;align-items:center;justify-content:center">'
                 '<div style="position:absolute;inset:8px;border-radius:50%;border:4px solid rgba(255,255,255,.85)"></div>'
                 f'{icon("flag", 56, "#fff", "text-shadow:0 1px 2px rgba(0,0,0,.25);")}</div>')
    epoch = "Built 1788–1791 · Kingdom of Prussia"
    content = f'''<div style="position:absolute;left:0;right:0;top:{cy+80}px;display:flex;flex-direction:column;align-items:center;gap:14px;text-align:center;color:#fff">
  <div style="font-size:34px;font-weight:700">Discovered!</div>
  <div style="display:flex;flex-direction:column;gap:2px"><div style="font-size:20px;font-weight:600;color:{GOLD}">{esc(name("brandenburger-tor"))}</div>
     <div class="sub" style="color:rgba(255,255,255,.75)">{esc(other_name("brandenburger-tor"))}</div></div>
  <div class="sub" style="font-weight:500;color:rgba(255,255,255,.9);display:flex;gap:6px;align-items:center">{icon("hourglass_top", 17)}{epoch}</div>
  <div class="sub" style="color:rgba(255,255,255,.8)">{COUNTS["discovered"]} of {COUNTS["game"]} sights discovered</div>
  <div class="sub" style="font-weight:600;background:rgba(255,149,0,.85);border-radius:20px;padding:6px 12px;display:flex;gap:6px;align-items:center">{icon("photo_camera", 17)}Entry unlocked · photograph it to capture it</div>
  <div style="margin-top:6px;background:#FF9500;color:#fff;border-radius:10px;padding:8px 20px;min-width:180px;font-size:17px;font-weight:600;display:flex;gap:7px;justify-content:center;align-items:center">{icon("photo_camera", 19)}Take a photo</div>
  <div style="display:flex;gap:12px">
    <div style="background:rgba(255,255,255,.2);border-radius:10px;padding:8px 14px;font-size:17px;font-weight:500;display:flex;gap:7px;align-items:center">{icon("menu_book", 19)}Read entry</div>
    <div style="background:rgba(255,255,255,.2);border-radius:10px;padding:8px 14px;font-size:17px;font-weight:500;display:flex;gap:7px;align-items:center">{icon("map", 19)}Show on map</div></div>
  <div class="caption" style="color:rgba(255,255,255,.6);margin-top:4px">Tap anywhere to continue</div>
</div>'''
    return page(f'<div class="screen">{map_layer(dim=0.7)}{rays}{"".join(sparks)}{medallion}{content}{status("light")}</div>')

GATE_SVG = """<svg viewBox="0 0 430 240" width="430" height="240" preserveAspectRatio="xMidYMid slice">
<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3d6fb0"/><stop offset=".55" stop-color="#e9a86b"/><stop offset="1" stop-color="#f6d29b"/></linearGradient>
<linearGradient id="stone" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e8d6b4"/><stop offset="1" stop-color="#b99a6c"/></linearGradient>
<linearGradient id="shade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6e5434"/><stop offset="1" stop-color="#3e2e1c"/></linearGradient></defs>
<rect width="430" height="240" fill="url(#sky)"/>
<circle cx="345" cy="150" r="34" fill="#ffe7b0" opacity=".55"/>
<rect x="0" y="206" width="430" height="34" fill="#8c7a63"/>
<g fill="url(#stone)">
 <rect x="60" y="92" width="310" height="22"/><rect x="66" y="80" width="298" height="12"/>
 <rect x="150" y="56" width="130" height="24"/><rect x="145" y="52" width="140" height="6"/>
 <rect x="56" y="196" width="318" height="12"/>
</g>
<g fill="url(#shade)"><rect x="76" y="114" width="278" height="82"/></g>
<g fill="url(#stone)">
 <rect x="72" y="114" width="14" height="82"/><rect x="117" y="114" width="14" height="82"/><rect x="162" y="114" width="14" height="82"/>
 <rect x="208" y="114" width="14" height="82"/><rect x="253" y="114" width="14" height="82"/><rect x="298" y="114" width="14" height="82"/>
 <rect x="344" y="114" width="14" height="82"/>
 <rect x="20" y="120" width="40" height="76"/><rect x="370" y="120" width="40" height="76"/><rect x="16" y="114" width="48" height="8"/><rect x="366" y="114" width="48" height="8"/>
</g>
<g fill="#2f5a4a"><path d="M188 52c2-10 10-14 16-14l4-10 6 10c6 0 12 4 14 14z"/><path d="M196 40l-6-12 8 4zM234 40l6-12-8 4z"/>
 <rect x="212" y="12" width="3" height="20"/><path d="M206 14h15l-3 6h-9z"/></g>
<rect x="0" y="206" width="430" height="2" fill="#6b5b47"/>
</svg>"""

def sheet(content, title, back=None, under_map=True, done="Done"):
    under = '<div class="under"><img src="map-fog.png" style="width:410px;height:auto;display:block;margin-top:-80px"></div>' if under_map else ""
    left = f'<div class="back">{icon("chevron_left", 30)}{back}</div>' if back else ""
    return page(f'''<div class="screen"><div class="backdrop"></div>{under}{status("light")}
<div class="sheet"><div class="nav">{left}{esc(title)}<div class="done">{done}</div></div>{content}</div></div>''')

def s3_entry():
    sid = "brandenburger-tor"
    text = INFO[sid]["text"].split("\n\n")
    banner = f'''<div style="position:relative;height:240px;overflow:hidden">{GATE_SVG}
<div style="position:absolute;inset:0;background:linear-gradient(transparent 50%, rgba(0,0,0,.75))"></div>
<div style="position:absolute;left:14px;bottom:14px;right:14px;display:flex;align-items:flex-end;gap:10px">{sight_badge("monument", "discovered", 40).replace("rgba(255,149,0,0.15)", "rgba(255,255,255,0.9)")}
<div style="display:flex;flex-direction:column;gap:2px"><div class="caption" style="font-weight:700;color:#FF9500">MONUMENT</div>
<div class="title2" style="color:#fff">{esc(name(sid))}</div><div class="sub" style="color:rgba(255,255,255,.85)">{esc(other_name(sid))}</div></div></div></div>'''
    body = f'''<div style="height:874px;overflow:hidden">{banner}
<div style="padding:16px;display:flex;flex-direction:column;gap:14px">
 <div class="sub" style="font-weight:600;color:#FF9500;display:flex;gap:6px;align-items:center">{icon("verified", 18)}Discovered 12 November 2026</div>
 <div style="background:rgba(255,149,0,.08);border:1px solid rgba(255,149,0,.3);border-radius:12px;padding:14px;display:flex;flex-direction:column;gap:10px">
   <div class="headline" style="color:#FF9500;display:flex;gap:6px;align-items:center">{icon("photo_camera", 20)}Capture it</div>
   <div class="sub" style="line-height:1.3">Photograph {esc(name(sid))} and keep the photo: it captures the sight and counts towards its achievements.</div>
   <div style="background:#FF9500;color:#fff;border-radius:10px;padding:9px;text-align:center;font-size:17px;font-weight:600;display:flex;gap:6px;justify-content:center;align-items:center">{icon("photo_camera", 19)}Take a photo</div>
 </div>
 <div class="body" style="line-height:1.32">{esc(text[0])}</div>
 <div class="body" style="line-height:1.32">{esc(text[1]) if len(text) > 1 else ""}</div>
</div></div>'''
    return sheet(body, name(sid))

def fact(title, value, symbol, detail=None, tint=ORANGE):
    d = f'<div class="caption secondary" style="line-height:1.3">{esc(detail)}</div>' if detail else ""
    return f'''<div style="display:flex;gap:10px;align-items:flex-start"><div style="width:22px;text-align:center;padding-top:2px">{icon(symbol, 17, tint)}</div>
<div style="display:flex;flex-direction:column;gap:2px"><div class="caption2 secondary" style="font-weight:700">{title.upper()}</div><div class="sub" style="line-height:1.3">{esc(value)}</div>{d}</div></div>'''

def s4_history():
    sid = "brandenburger-tor"
    h = HISTORY[sid]
    history = h["history"].split("\n\n")[0]
    card = f'''<div style="background:rgba(255,149,0,.08);border:1px solid rgba(255,149,0,.3);border-radius:12px;padding:14px;display:flex;flex-direction:column;gap:12px">
<div class="headline" style="color:#FF9500;display:flex;gap:6px;align-items:center">{icon("hourglass_top", 20)}In history</div>
{fact("Built", h["built"], "construction")}{fact("Opened", h["opened"], "door_open")}
{fact("Style", ", ".join(h["styles"]), "account_balance")}
{fact("Architects and artists", ", ".join(h["architects"]), "architecture")}
{fact("Commissioned by", ", ".join(h["commissionedBy"]), "draw")}
{fact("Ruling in 1788", "Frederick William II (Friedrich Wilhelm II.), King of Prussia (1786–1797)", "crown")}
{fact("Era", "Kingdom of Prussia (1701–1871)", "history", "Berlin is the royal capital: Baroque and Rococo under the first kings, then Neoclassicism, Schinkel's city, after the Napoleonic Wars.")}
</div>'''
    body = f'''<div style="padding:8px 16px;display:flex;flex-direction:column;gap:16px;height:874px;overflow:hidden">{card}
<div><div class="headline" style="margin-bottom:8px">History</div><div class="body" style="line-height:1.32;max-height:156px;overflow:hidden;-webkit-mask-image:linear-gradient(#000 70%,transparent)">{esc(history)}</div>
<div class="sub" style="color:{ACCENT};margin-top:6px;display:flex;gap:4px;align-items:center">{icon("expand_more", 20)}Read more</div></div>
<div style="background:rgba(245,153,46,.15);color:{ACCENT};border-radius:10px;padding:9px;text-align:center;font-size:17px;font-weight:600;display:flex;gap:6px;justify-content:center;align-items:center">{icon("map", 19)}Show on map</div>
</div>'''
    return sheet(body, name(sid))

def tabs(on):
    names = ["Sights", "Achievements", "Remembrance"]
    return '<div style="padding:4px 16px 16px"><div class="seg">' + "".join(f'<div class="{"on" if n == on else ""}">{n}</div>' for n in names) + "</div></div>"

def s5_timeline():
    shown = ["deutscher-dom", "franzoesischer-dom", "bebelplatz", "staatsoper", "hedwigs-kathedrale",
             "dorotheenstaedtischer-friedhof", "brandenburger-tor", "neue-wache"]
    rows = []
    for sid in shown:
        h = HISTORY[sid]; s = SIGHTS[sid]
        year = h["year"]
        if s["category"] in ("memorial", "cemetery"):
            rows.append(f'''<div class="row" style="align-items:flex-start">
<div class="sub secondary" style="width:42px;font-variant-numeric:tabular-nums;padding-top:2px">{year}</div>{sight_badge(s["category"], "", 34)}
<div style="display:flex;flex-direction:column;gap:2px;flex:1"><div class="body">{esc(name(sid))}</div>
<div class="caption secondary">Place of remembrance · not part of the game</div></div>{icon("chevron_right", 22, "rgba(60,60,67,.3)")}</div>''')
            continue
        state = "captured" if sid in CAPTURED or sid in ("schloss-charlottenburg",) else "discovered" if sid in DISCOVERED or sid in ("hedwigs-kathedrale", "zitadelle") else ""
        col = ORANGE if state else "rgba(60,60,67,0.6)"
        ruler = ""
        detail = s["category"].title()
        if state:
            styles = h.get("styles") or []
            from_ruler = {1701: "Frederick I", 1713: "Frederick William I", 1740: "Frederick the Great", 1786: "Frederick William II",
                          1797: "Frederick William III", 1840: "Frederick William IV", 1861: "William I"}
            r = [v for k, v in sorted(from_ruler.items()) if k <= year][-1]
            detail = " · ".join([x for x in [styles[0] if styles else None, r] if x])
        mark = icon("verified", 20, ORANGE) if state == "captured" else icon("photo_camera", 20, ORANGE) if state else icon("lock", 18, "rgba(60,60,67,.6)")
        weight = "600" if state == "captured" else "400"
        rows.append(f'''<div class="row"><div class="sub" style="width:42px;font-weight:600;color:{col};font-variant-numeric:tabular-nums">{year}</div>{sight_badge(s["category"], state, 34)}
<div style="display:flex;flex-direction:column;gap:2px;flex:1;min-width:0"><div class="body" style="font-weight:{weight};color:{col};white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{esc(name(sid))}</div>
<div class="caption secondary" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{esc(detail)}</div></div>{mark}</div>''')
    header = f'''<div class="list"><div class="section" style="padding:12px 16px;display:flex;flex-direction:column;gap:8px">
<div class="headline">{COUNTS["captured"]} of {COUNTS["game"]} sights captured</div>
<div class="sub secondary">{COUNTS["discovered"]} discovered · {COUNTS["stations"]} of {COUNTS["all_stations"]} stations collected</div>
<div class="progress"><div style="width:{COUNTS["captured"]/COUNTS["game"]*100:.1f}%"></div></div>
<div class="seg" style="margin-top:4px"><div>Nearby</div><div class="on">Through time</div></div></div>
<div class="section-footer">Berlin's history in its sights, by the year they were built. Places of remembrance stand in their year, in grey: they are not part of the game.</div>
<div style="padding:6px 16px 8px"><div style="display:flex;justify-content:space-between;align-items:baseline"><span class="headline">Kingdom of Prussia</span><span class="sub secondary">1701–1871</span></div>
<div class="caption secondary" style="line-height:1.3;margin-top:3px">Berlin is the royal capital: Baroque and Rococo under the first kings, then Neoclassicism, Schinkel's city, after the Napoleonic Wars.</div></div>
<div class="section">{"".join(rows)}</div></div>'''
    return sheet(tabs("Sights") + header, "Sights")

def achievement_row(aid, count, target):
    a = ACHIEVEMENTS[aid]
    complete = count >= target
    frac = min(1, count / target)
    return f'''<div class="row" style="padding:10px 16px">{medal(a["symbol"], frac, complete)}
<div style="display:flex;flex-direction:column;gap:3px;flex:1;min-width:0">
<div class="headline" style="color:{ORANGE if complete else "#000"}">{esc(a["title"])}</div>
<div class="caption secondary" style="line-height:1.3;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">{esc(a["description"])}</div>
<div style="display:flex;gap:8px;align-items:center"><div class="progress" style="flex:1"><div style="width:{frac*100:.0f}%;background:{GOLD if complete else ORANGE}"></div></div>
<span class="caption secondary" style="font-variant-numeric:tabular-nums">{min(count, target)}/{target}</span></div></div>{icon("chevron_right", 22, "rgba(60,60,67,.3)")}</div>'''

def s6_achievements():
    header = f'''<div class="list"><div class="section" style="padding:12px 16px;display:flex;flex-direction:column;gap:8px">
<div class="headline">{COUNTS["achievements"]} of {COUNTS["all_achievements"]} achievements completed</div>
<div class="progress"><div style="width:{COUNTS["achievements"]/COUNTS["all_achievements"]*100:.1f}%"></div></div>
<div class="seg" style="margin-top:4px"><div class="on">All</div><div>Completed</div><div>Started</div><div>Not started</div></div></div>
<div class="section-header">Almost there</div>
<div class="section">{achievement_row("gendarmenmarkt", 3, 4)}{achievement_row("unter-den-linden", 5, 7)}{achievement_row("old-fritz", 4, 6)}</div>
<div class="section-header">Milestones · 2/6</div>
<div class="section">{achievement_row("first-capture", 1, 1)}{achievement_row("captures-10", 10, 10)}{achievement_row("captures-25", 23, 25)}</div></div>'''
    return sheet(tabs("Achievements") + header, "Achievements")

def s7_line():
    line = next(l for l in STATIONS["lines"] if l["id"] == "U6")
    ids = line["stations"]
    collected = {"u:friedrichstrasse", "u:unter-den-linden", "u:stadtmitte", "u:kochstrasse-checkpoint-charlie", "u:hallesches-tor",
                 "u:platz-der-luftbruecke", "u:paradestrasse", "u:tempelhof", "u:oranienburger-tor", "u:naturkundemuseum",
                 "u:alt-tempelhof"}
    done = sum(1 for i in ids if i in collected)
    rows = []
    start = ids.index("u:platz-der-luftbruecke") if "u:platz-der-luftbruecke" in ids else 0
    for sid in ids[start:start + 8]:
        st = STATION[sid]; got = sid in collected
        others = [l for l in st["lines"] if l != "U6"]
        detail = ("collected · " if got else "") + ("U6" + (" · " + ", ".join(others) if others else ""))
        rows.append(f'''<div class="row">{line_sign("U", 22, got)}<div style="display:flex;flex-direction:column;gap:1px;flex:1">
<div class="sub" style="font-weight:600;color:{"#000" if got else "rgba(60,60,67,.6)"}">{esc(st["name"])}</div><div class="caption secondary">{esc(detail)}</div></div>
{icon("check_circle", 20, ORANGE) if got else ""}</div>''')
    a = ACHIEVEMENTS["line-u6"]
    frac = done / len(ids)
    nxt = STATION["u:mehringdamm"]
    body = f'''<div class="list" style="padding-top:6px">
<div class="section" style="padding:16px;display:flex;flex-direction:column;align-items:center;gap:8px;text-align:center">
<div style="position:relative">{medal(a["symbol"], frac, False, 72)}<div style="position:absolute;left:21px;top:21px">{line_sign("U", 30)}</div></div>
<div class="title2">{esc(a["title"])}</div><div class="sub secondary" style="line-height:1.3">{esc(a["description"])}</div>
<div class="progress" style="width:100%;margin-top:4px"><div style="width:{frac*100:.0f}%"></div></div>
<div class="caption secondary">{done} of {len(ids)} – {len(ids) - done} to go</div></div>
<div class="section-header">Next up: the nearest</div>
<div class="section"><div class="row">{line_sign("U", 22, False)}<div style="display:flex;flex-direction:column;gap:1px;flex:1"><div class="sub" style="font-weight:600">{esc(nxt["name"])}</div>
<div class="caption secondary">2.1 km away · {", ".join(nxt["lines"])}</div></div><div class="sub" style="color:{ACCENT};display:flex;gap:4px;align-items:center">{icon("map", 18)}Show on map</div></div></div>
<div class="section-header">Stations · {done}/{len(ids)}</div>
<div class="section">{"".join(rows)}</div></div>'''
    return sheet(body, "Line U6", back="Achievements", done="")

def s8_remembrance():
    ch = REMEMBRANCE["chapters"][0]
    places = []
    for p in ch["places"]:
        s = SIGHTS[p["sight"]]
        places.append(f'''<div class="row" style="align-items:flex-start;padding:11px 16px">{sight_badge(s["category"], "", 30)}
<div style="display:flex;flex-direction:column;gap:3px;flex:1"><div class="body">{esc(name(p["sight"]))}</div>
<div class="sub secondary" style="line-height:1.3">{esc(p["remembers"])}</div></div>{icon("chevron_right", 22, "rgba(60,60,67,.3)")}</div>''')
    intro = ("Memorials, memorial sites and cemeteries keep the memory of the people who were persecuted, murdered and killed in war, "
             "and of those who resisted. They are not part of the game: there is nothing to capture or collect, and every entry is open. "
             "Read about them here, or visit them on a walk – in your own time, and with respect.")
    body = f'''<div class="list">
<div class="section" style="padding:14px 16px;display:flex;flex-direction:column;gap:8px"><div class="title3" style="font-weight:600">Berlin remembers</div>
<div class="sub secondary" style="line-height:1.32">{intro}</div></div>
<div style="padding:4px 16px 8px;display:flex;justify-content:space-between;align-items:baseline"><span class="headline">{esc(ch["title"])}</span><span class="sub secondary">{ch["years"]}</span></div>
<div class="section"><div class="row plain" style="padding:11px 16px"><div class="sub secondary" style="line-height:1.32">{esc(ch["text"])}</div></div>{"".join(places)}</div></div>'''
    return sheet(tabs("Remembrance") + body, "Remembrance")

def s9_german():
    def row(title, sym, tint, detail=None):
        d = f'<span class="body secondary" style="margin-left:auto">{esc(detail)}</span>' if detail else '<span style="margin-left:auto"></span>'
        return (f'<div class="row"><div class="badge" style="width:28px;height:28px;border-radius:7px;background:{tint}">{icon(sym, 17, "#fff")}</div>'
                f'<span class="body">{esc(title)}</span>{d}{icon("chevron_right", 22, "rgba(60,60,67,.3)")}</div>')
    t = lambda k: DE.get(k, k)
    body = f'''<div class="list" style="padding-top:6px">
<div class="section">{row(t("Map view"), "map", "#007AFF", "2D · " + t("Fog") + " · " + t("All time"))}{row(t("Statistics"), "bar_chart", "#5856D6", "2,41 km²")}</div>
<div class="section-header">{t("Recording")}</div>
<div class="section">{row(t("Recording"), "near_me", "#34C759", t("On"))}{row(t("Data source"), "group", "#30B0C7", t("My discoveries"))}</div>
<div class="section-header">{t("Data")}</div>
<div class="section">{row(t("Discovered area"), "select_all", "#FF9500")}{row(t("Building data"), "domain", "#A2845E")}{row(t("Map data"), "hard_drive", "#8E8E93")}</div>
<div class="section">{row(t("Language"), "language", "#32ADE6", "Deutsch")}</div>
<div class="section-footer">{esc(t("Names keep their German original next to the English name. The system's own dialogs (camera, permissions) follow the next time the app starts."))}</div>
<div class="section-header">{t("Developer")}</div>
<div class="section">{row(t("Debug settings"), "tune", "#AF52DE")}</div>
</div>'''
    return sheet(body, t("Menu"), done=t("Done"))

SCREENS = [
    ("01-map", s1_map, "Lift the fog", "Walk Berlin – every street you take is revealed on your map.", "linear-gradient(160deg,#1b1d24,#07080b)", "#fff", GOLD),
    ("02-discovered", s2_celebration, "Discover. Then capture.", "Reach a sight to unlock its story – photograph it there to capture it.", "linear-gradient(160deg,#ffcf5a,#ff8a00)", "#1a1206", "#1a1206"),
    ("03-entry", s3_entry, "Every sight has a story", "184 sights across all twelve districts, each with its entry.", "linear-gradient(160deg,#f6e3c3,#e9c38f)", "#2a1d0c", "#a3560b"),
    ("04-history", s4_history, "History on every corner", "When it was built, by whom, for whom – and who ruled Berlin then.", "linear-gradient(160deg,#fff4e5,#ffd9a8)", "#2a1d0c", "#c46a00"),
    ("05-timeline", s5_timeline, "Travel through time", "From Slavic lands to reunified Berlin, sight by sight.", "linear-gradient(160deg,#1f2a44,#111725)", "#fff", "#ffb75e"),
    ("06-achievements", s6_achievements, "102 achievements", "Eras, master builders, districts, collections – and every line.", "linear-gradient(160deg,#ff9f2e,#e2580b)", "#fff", "#fff3d6"),
    ("07-lines", s7_line, "Ride every line", "343 U-Bahn and S-Bahn stations, collected just by passing through.", "linear-gradient(160deg,#0065AE,#008D4F)", "#fff", "#d8f0ff"),
    ("08-remembrance", s8_remembrance, "Places of remembrance", "Outside the game: a short history and quiet walks, told with respect.", "linear-gradient(160deg,#5b6169,#3a3e44)", "#fff", "rgba(255,255,255,.75)"),
    ("09-deutsch", s9_german, "English & Deutsch", "Names keep their German original. Switch the language any time.", "linear-gradient(160deg,#2e3a3f,#151b1e)", "#fff", "#9fe3d0"),
]

def store_page(shot, headline, sub, background, color, accent):
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0}} body{{width:430px;height:932px;overflow:hidden;background:{background};font-family:'Inter Display','Inter',sans-serif;
-webkit-font-smoothing:antialiased;position:relative}}
.h{{position:absolute;left:28px;right:28px;top:48px;color:{color};font-size:34px;font-weight:800;letter-spacing:-0.025em;line-height:1.05}}
.s{{position:absolute;left:28px;right:28px;top:94px;color:{accent};font-family:'Inter',sans-serif;font-size:16px;font-weight:500;line-height:1.3}}
.phone{{position:absolute;left:50%;top:170px;width:350px;height:758px;margin-left:-175px;border-radius:52px;background:#0c0c0e;padding:9px;
box-shadow:0 30px 60px rgba(0,0,0,.35), inset 0 0 0 2px #2a2a2e}}
.phone img{{width:332px;height:720px;border-radius:44px;display:block;object-fit:cover;object-position:top}}
.island{{position:absolute;left:50%;top:20px;width:100px;height:29px;margin-left:-50px;border-radius:15px;background:#000}}
</style></head><body><div class="h">{headline}</div><div class="s">{sub}</div>
<div class="phone"><img src="{shot}.png"><div class="island"></div></div></body></html>"""


if __name__ == "__main__":
    import subprocess, sys
    only = sys.argv[1:]
    shoot = str(pathlib.Path(__file__).with_name("shoot.js"))
    for key, make, headline, sub, bg, color, accent in SCREENS:
        if only and key not in only:
            continue
        (SHOTS / f"{key}.html").write_text(make())
        subprocess.run(["node", shoot, str(SHOTS / f"{key}.html"), str(SHOTS / f"{key}.png"), "430", "932", "3"], check=True)
        (SHOTS / f"store-{key}.html").write_text(store_page(key, headline, sub, bg, color, accent))
        subprocess.run(["node", shoot, str(SHOTS / f"store-{key}.html"), str(SHOTS / f"store-{key}.png"), "430", "932", "3"], check=True)
        print("built", key)
