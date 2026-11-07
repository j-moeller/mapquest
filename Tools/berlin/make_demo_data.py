"""Generates demo position data for Berlin.

* App/MapQuest/Resources/Berlin/demo-walks.json – raw position fixes of a fictional
  "demo explorer" (several walks on different days). The app imports them through
  the LocationRecorder into a view-only profile, which demonstrates switching the
  data source to another user's data.
* App/Simulation/BerlinWalk.gpx – Brandenburger Tor → Alexanderplatz at walking
  speed, used by the Xcode scheme to simulate a walk in the iOS Simulator.

Routes follow well-known straight streets; coordinates are approximate.
Usage: python3 Tools/berlin/make_demo_data.py
"""
import datetime as dt
import json
import math
import pathlib
import random
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
NAMESPACE = uuid.UUID("6f1c2b1e-6d0b-4f3a-9a52-1b9d5f6e7c11")

UNTER_DEN_LINDEN = [  # Brandenburger Tor → Alexanderplatz
    (52.51627, 13.37770), (52.51640, 13.38070), (52.51690, 13.38500), (52.51720, 13.39000),
    (52.51745, 13.39500), (52.51760, 13.39820), (52.51790, 13.39950), (52.51900, 13.40250),
    (52.52050, 13.40640), (52.52190, 13.41000), (52.52230, 13.41250),
]
STRASSE_DES_17_JUNI = [(52.51630, 13.37650), (52.51450, 13.35010)]  # → Großer Stern
FRIEDRICHSTRASSE = [  # Oranienburger Tor → Mehringplatz
    (52.52500, 13.38780), (52.52020, 13.38710), (52.51711, 13.38878),
    (52.50750, 13.39040), (52.49830, 13.39160),
]
TEMPELHOFER_FELD = [(52.47650, 13.39500), (52.47350, 13.41200)]
BERGMANNSTRASSE = [(52.48930, 13.38700), (52.48880, 13.39900), (52.48900, 13.40800)]

WALKS = [  # (route, start time UTC)
    (UNTER_DEN_LINDEN, "2026-09-12T09:10:00Z"),
    (STRASSE_DES_17_JUNI, "2026-09-12T10:05:00Z"),
    (FRIEDRICHSTRASSE, "2026-09-19T14:30:00Z"),
    (TEMPELHOFER_FELD, "2026-09-27T11:00:00Z"),
    (BERGMANNSTRASSE, "2026-10-03T16:45:00Z"),
]

SPEED = 1.4          # m/s walking speed
FIX_INTERVAL = 3.0   # seconds between fixes in demo-walks.json
GPX_INTERVAL = 2.0   # seconds between GPX waypoints
GROUND = 36.0        # metres above sea level


def metres(a, b):
    k = math.cos(math.radians((a[0] + b[0]) / 2))
    return math.hypot((b[0] - a[0]) * 111_320, (b[1] - a[1]) * 111_320 * k)


def interpolate(route, spacing):
    """Points every `spacing` metres along a polyline."""
    points = [route[0]]
    carry = 0.0
    for a, b in zip(route, route[1:]):
        length = metres(a, b)
        t = spacing - carry
        while t <= length:
            f = t / length
            points.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            t += spacing
        carry = length - (t - spacing)
    if points[-1] != route[-1]:
        points.append(route[-1])
    return points


def parse(ts):
    return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def iso(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def demo_walks():
    rng = random.Random(1234)
    samples = []
    for route, start in WALKS:
        t0 = parse(start)
        for i, (lat, lon) in enumerate(interpolate(route, SPEED * FIX_INTERVAL)):
            # GPS noise with σ ≈ 2 m.
            dn, de = rng.gauss(0, 2), rng.gauss(0, 2)
            lat += dn / 111_320
            lon += de / (111_320 * math.cos(math.radians(lat)))
            t = t0 + dt.timedelta(seconds=i * FIX_INTERVAL)
            samples.append({
                "id": str(uuid.uuid5(NAMESPACE, f"{start}-{i}")).upper(),
                "latitude": round(lat, 7),
                "longitude": round(lon, 7),
                "altitude": round(GROUND + rng.gauss(0, 1.5), 1),
                "horizontalAccuracy": round(abs(rng.gauss(5, 1.5)) + 2, 1),
                "verticalAccuracy": round(abs(rng.gauss(4, 1)) + 2, 1),
                "timestamp": iso(t),
            })
    return samples


def gpx(route, start):
    t0 = parse(start)
    lines = ['<?xml version="1.0"?>', '<gpx version="1.1" creator="MapQuest Tools/berlin/make_demo_data.py">']
    for i, (lat, lon) in enumerate(interpolate(route, SPEED * GPX_INTERVAL)):
        t = t0 + dt.timedelta(seconds=i * GPX_INTERVAL)
        lines.append(f'    <wpt lat="{lat:.7f}" lon="{lon:.7f}"><ele>{GROUND:.1f}</ele><time>{iso(t)}</time></wpt>')
    lines.append("</gpx>")
    return "\n".join(lines) + "\n"


def main():
    samples = demo_walks()
    out = ROOT / "App" / "MapQuest" / "Resources" / "Berlin" / "demo-walks.json"
    out.write_text(json.dumps(samples, separators=(",", ":")), encoding="utf-8")
    print(f"{out.relative_to(ROOT)}: {len(samples)} fixes")
    gpx_path = ROOT / "App" / "Simulation" / "BerlinWalk.gpx"
    gpx_path.parent.mkdir(parents=True, exist_ok=True)
    gpx_path.write_text(gpx(UNTER_DEN_LINDEN, "2026-01-01T10:00:00Z"), encoding="utf-8")
    print(f"{gpx_path.relative_to(ROOT)} written")


if __name__ == "__main__":
    main()
