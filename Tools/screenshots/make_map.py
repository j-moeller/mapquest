"""The map of the main view with the fog of war over it, as FogMapRenderer draws it:
the base map, and outside the discovered area the map blurred (σ 4 pt) and
darkened (black, 80 %) with a soft edge (10 m). From base.svgfrag and
discovered.d (MockupMapExportTests); writes map-fog.html to render."""
from common import K, SHOTS, VIEW

def main():
    vx, vy, w, h = VIEW["vx"], VIEW["vy"], 430 * K, 932 * K
    base = (SHOTS / "base.svgfrag").read_text()
    pieces = [line for line in (SHOTS / "discovered.d").read_text().split("\n") if line.strip()]
    blur, soft = 4 * K, 10 * 0.688 / 2   # 25 % of 16 pt; 10 m at 0.688 frame pixels per metre
    area = f'x="{vx-200}" y="{vy-200}" width="{w+400}" height="{h+400}"'
    region = f'filterUnits="userSpaceOnUse" x="{vx-100}" y="{vy-100}" width="{w+200}" height="{h+200}"'
    discovered = "".join(f'<path d="{d}" fill="#000" fill-rule="evenodd"/>' for d in pieces)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vx} {vy} {w:.1f} {h:.1f}" width="430" height="932">
<defs><g id="base">{base}</g>
<filter id="b" {region}><feGaussianBlur stdDeviation="{blur:.1f}"/></filter>
<filter id="s" {region}><feGaussianBlur stdDeviation="{soft:.1f}"/></filter>
<mask id="m" maskUnits="userSpaceOnUse" {area}><rect {area} fill="#fff"/><g filter="url(#s)">{discovered}</g></mask></defs>
<use href="#base"/>
<g mask="url(#m)"><use href="#base" filter="url(#b)"/><rect {area} fill="#000" fill-opacity="0.8"/></g>
</svg>'''
    (SHOTS / "map-fog.html").write_text(
        f'<!doctype html><html><head><meta charset="utf-8"><style>html,body{{margin:0;background:#000}}svg{{display:block}}</style></head><body>{svg}</body></html>')

if __name__ == "__main__":
    main()
