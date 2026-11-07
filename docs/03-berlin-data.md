# MapQuest – Berlin data

Berlin is the first play area. This page lists every dataset the app uses for
Berlin, where it comes from, and how to regenerate it.

## 2D

| Data | Source | Licence | File |
|---|---|---|---|
| Base map | Apple Maps via MapKit | Apple Maps terms | – (streamed by MapKit) |
| District boundaries (12 Bezirke) | Amt für Statistik Berlin-Brandenburg, merged from localities by [m-hoerz/berlin-shapes](https://github.com/m-hoerz/berlin-shapes) | CC BY 3.0 DE | `App/MapQuest/Resources/Berlin/berlin-districts.geojson` |
| City outline | Union of the districts (slivers closed, simplified to 2 m) | CC BY 3.0 DE | `App/MapQuest/Resources/Berlin/berlin-boundary.geojson` |
| Demo explorer walks | Generated (`Tools/berlin/make_demo_data.py`) | – | `App/MapQuest/Resources/Berlin/demo-walks.json` |
| Simulator walk | Generated, Brandenburger Tor → Alexanderplatz | – | `App/Simulation/BerlinWalk.gpx` |

For the 2D map no geographic data has to be shipped: Apple Maps provides the
base map, and the fog is computed from the user's own positions. Berlin data is
needed to

* **restrict recording** to Berlin (`PlayArea`, point-in-polygon per fix),
* **compute statistics** – discovered share of Berlin and of each district
  (`DiscoveryStatistics.coverage`, computed tile by tile),
* **draw the boundary** as a dashed outline,
* **demonstrate data-source switching**: the view-only *Demo explorer*
  profile is filled on first use by feeding its 2 372 raw fixes through the
  `LocationRecorder`, which stores only the fixes that reveal new area and
  builds the discovered area – three regions (central Mitte, Tempelhofer Feld,
  Bergmannstraße).

The play-area code is global: replacing the two GeoJSON files (or using
`PlayArea.world`) moves the game to another city or the whole world.

### Regenerating

```bash
pip install shapely
python3 Tools/berlin/prepare_play_area.py
python3 Tools/berlin/make_demo_data.py
```

### Simulating a walk

The Xcode scheme uses `App/Simulation/BerlinWalk.gpx` as the default simulated
location, so running in the iOS Simulator walks from the Brandenburger Tor
along Unter den Linden to Alexanderplatz at 1.4 m/s. Other locations can be
picked from Xcode's *Debug › Simulate Location* menu.

## 3D

See the 3D section below (added with the 3D implementation).
