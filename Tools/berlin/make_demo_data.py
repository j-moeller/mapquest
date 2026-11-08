"""Generates demo position data.

* App/MapQuest/Resources/Berlin/demo-track.mqtrack – the 1 Hz track of a fictional
  "demo explorer" (TrackCodec v1, see MapQuestCore/Track/TrackPoint.swift): walks
  in Berlin on several days, ten weekday commutes Bergmannstraße ↔ Friedrichstraße
  with short stays at both ends, and a day trip to Braunschweig. The app imports
  it through the LocationRecorder into a view-only profile, which demonstrates
  switching the data source to another user's data and the time-based views.
* App/Simulation/BerlinWalk.gpx – Brandenburger Tor → Alexanderplatz at walking
  speed, used by the Xcode scheme to simulate a walk in the iOS Simulator.

Routes follow well-known straight streets; coordinates are approximate.
Usage: python3 Tools/berlin/make_demo_data.py
"""
import datetime as dt
import math
import pathlib
import random

ROOT = pathlib.Path(__file__).resolve().parents[2]

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

COMMUTE = [  # Bergmannstraße → Mehringdamm → Friedrichstraße → Oranienburger Tor
    (52.48900, 13.40800), (52.48880, 13.39900), (52.48930, 13.38700), (52.49380, 13.38720),
    (52.49830, 13.39160), (52.50750, 13.39040), (52.51711, 13.38878), (52.52020, 13.38710),
    (52.52500, 13.38780),
]
BRAUNSCHWEIG = [  # Hauptbahnhof → Schloss → Burgplatz → Altstadtmarkt → Kohlmarkt → Hauptbahnhof
    (52.25240, 10.53970), (52.25700, 10.53300), (52.26150, 10.52900), (52.26370, 10.52810),
    (52.26420, 10.52360), (52.26300, 10.51900), (52.26230, 10.51670), (52.26250, 10.52050),
    (52.25900, 10.52400), (52.25500, 10.53300), (52.25240, 10.53970),
]

WALKS = [  # (route, start time UTC)
    (UNTER_DEN_LINDEN, "2026-09-12T09:10:00Z"),
    (STRASSE_DES_17_JUNI, "2026-09-12T10:05:00Z"),
    (FRIEDRICHSTRASSE, "2026-09-19T14:30:00Z"),
    (TEMPELHOFER_FELD, "2026-09-27T11:00:00Z"),
    (BERGMANNSTRASSE, "2026-10-03T16:45:00Z"),
    (BRAUNSCHWEIG, "2026-10-24T10:30:00Z"),
]
COMMUTE_DAYS = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16",
                "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"]
STAY = 600  # seconds at home/office before and after each commute

SPEED = 1.4          # m/s walking speed
FIX_INTERVAL = 1.0   # seconds between track fixes
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


def fix(rng, t, lat, lon, noise=2.0, accuracy=5.0, ground=GROUND):
    """A fix with GPS noise (σ = `noise` metres) at time t (datetime)."""
    dn, de = rng.gauss(0, noise), rng.gauss(0, noise)
    lat += dn / 111_320
    lon += de / (111_320 * math.cos(math.radians(lat)))
    return (t.timestamp(), lat, lon, ground + rng.gauss(0, 1.5),
            abs(rng.gauss(accuracy, 1.5)) + 2, abs(rng.gauss(4, 1)) + 2)


def walk(rng, route, t0, ground=GROUND):
    return [fix(rng, t0 + dt.timedelta(seconds=i * FIX_INTERVAL), lat, lon, ground=ground)
            for i, (lat, lon) in enumerate(interpolate(route, SPEED * FIX_INTERVAL))]


def stay(rng, place, t0, seconds):
    # Indoors: worse accuracy, slowly drifting jitter.
    return [fix(rng, t0 + dt.timedelta(seconds=i), place[0], place[1], noise=5, accuracy=12)
            for i in range(seconds)]


def demo_track():
    rng = random.Random(1234)
    fixes = []
    for route, start in WALKS:
        ground = 75.0 if route is BRAUNSCHWEIG else GROUND
        fixes += walk(rng, route, parse(start), ground=ground)
    for day in COMMUTE_DAYS:
        morning = parse(f"{day}T06:50:00Z")
        fixes += stay(rng, COMMUTE[0], morning, STAY)
        there = walk(rng, COMMUTE, morning + dt.timedelta(seconds=STAY))
        fixes += there
        fixes += stay(rng, COMMUTE[-1], morning + dt.timedelta(seconds=STAY + len(there)), STAY)
        evening = parse(f"{day}T16:30:00Z")
        fixes += stay(rng, COMMUTE[-1], evening, STAY)
        back = walk(rng, list(reversed(COMMUTE)), evening + dt.timedelta(seconds=STAY))
        fixes += back
        fixes += stay(rng, COMMUTE[0], evening + dt.timedelta(seconds=STAY + len(back)), STAY)
    fixes.sort(key=lambda f: f[0])
    return fixes


def varint(value, out):
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)


def zigzag(value, out):
    varint((value << 1) ^ (value >> 63) if value < 0 else value << 1, out)


def encode_track(fixes):
    """TrackCodec v1: quantize (0.1 s, 1e-6°, dm) and zig-zag-varint the deltas."""
    out = bytearray([1])
    varint(len(fixes), out)
    previous = (0, 0, 0, 0, 0, 0)
    for t, lat, lon, alt, hacc, vacc in fixes:
        current = (round(t * 10), round(lat * 1e6), round(lon * 1e6), round(alt * 10), round(hacc * 10), round(vacc * 10))
        for value, before in zip(current, previous):
            zigzag(value - before, out)
        previous = current
    return bytes(out)


def gpx(route, start):
    t0 = parse(start)
    lines = ['<?xml version="1.0"?>', '<gpx version="1.1" creator="MapQuest Tools/berlin/make_demo_data.py">']
    for i, (lat, lon) in enumerate(interpolate(route, SPEED * GPX_INTERVAL)):
        t = t0 + dt.timedelta(seconds=i * GPX_INTERVAL)
        lines.append(f'    <wpt lat="{lat:.7f}" lon="{lon:.7f}"><ele>{GROUND:.1f}</ele><time>{iso(t)}</time></wpt>')
    lines.append("</gpx>")
    return "\n".join(lines) + "\n"


def main():
    fixes = demo_track()
    out = ROOT / "App" / "MapQuest" / "Resources" / "Berlin" / "demo-track.mqtrack"
    data = encode_track(fixes)
    out.write_bytes(data)
    print(f"{out.relative_to(ROOT)}: {len(fixes)} fixes, {len(data)} bytes ({len(data) / len(fixes):.1f} per fix)")
    gpx_path = ROOT / "App" / "Simulation" / "BerlinWalk.gpx"
    gpx_path.parent.mkdir(parents=True, exist_ok=True)
    gpx_path.write_text(gpx(UNTER_DEN_LINDEN, "2026-01-01T10:00:00Z"), encoding="utf-8")
    print(f"{gpx_path.relative_to(ROOT)} written")


if __name__ == "__main__":
    main()
