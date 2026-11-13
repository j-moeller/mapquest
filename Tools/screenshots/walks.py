"""A few walks added to the demo explorer's track for the map mockup, traced along
streets on the map view (screen points of the 430 × 932 view: Ebertstraße,
Behrenstraße, around Gendarmenmarkt, Französische Straße, Leipziger Straße, the
Spree to the Reichstag, Wilhelmstraße). Writes one "lat lon" per line, walks
separated by blank lines (MockupMapExportTests reads them)."""
import sys
from common import K, VIEW, unframe

WALKS = [
    [(15, 386), (30, 402), (38, 432), (36, 520), (33, 600), (30, 662)],
    [(45, 515), (120, 495), (200, 478), (300, 472), (388, 468), (390, 420)],
    [(298, 425), (298, 500), (298, 592), (336, 590), (336, 500), (298, 500)],
    [(200, 506), (300, 503), (420, 498)],
    [(20, 668), (130, 657), (250, 647), (340, 637), (430, 626)],
    [(340, 428), (343, 470)],
    [(232, 350), (160, 352), (100, 360), (40, 369), (15, 386)],
    [(205, 478), (208, 560), (212, 645)],
]

if __name__ == "__main__":
    with open(sys.argv[1], "w") as f:
        for walk in WALKS:
            for x, y in walk:
                f.write("%.7f %.7f\n" % unframe(VIEW["vx"] + x * K, VIEW["vy"] + y * K))
            f.write("\n")
