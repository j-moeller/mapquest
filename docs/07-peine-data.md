# MapQuest – Peine data

Peine is the third bundled city. Unlike Berlin and Braunschweig, its data does
not come from OpenStreetMap: OSM's download servers (Geofabrik, Overpass) were
not reachable from the build environment, so everything is official open data.
It is built by `Tools/cities/build_city.sh` in its OSM-free mode and committed
to `App/MapQuest/Resources/Peine/`:

```bash
Tools/cities/build_city.sh --id peine --name Peine --vg250 DE_VG250.gpkg --ags 03157006 --viewshed "Marktplatz (street)@52.32030,10.23370"
```

| Data | Source | Licence | File |
|---|---|---|---|
| Town outline | BKG *Verwaltungsgebiete 1:250 000* (VG250, as of 1 January 2026), municipality 03157006, land area | Datenlizenz Deutschland – Namensnennung – 2.0 | `peine-boundary.geojson` |
| Districts | – (VG250 has none; the app lists Peine as a whole) | – | – |
| Buildings | LGLN OpenGeoData *3D-Gebäudemodelle LoD2*: every building and building part with its own ground polygon and measured height (`Tools/cities/lod2_buildings.py`) | Datenlizenz Deutschland – Namensnennung – 2.0 | `peine-buildings.sqlite.deflate` |
| Terrain | LGLN OpenGeoData *DGM1*, averaged to 25 m and resampled to a ≈ 30 m grid | Datenlizenz Deutschland – Namensnennung – 2.0 | `peine-terrain.dem` |

Attribution: © GeoBasis-DE / BKG (2026); © LGLN – Landesamt für
Geoinformation und Landesvermessung Niedersachsen (dl-de/by-2-0).

VG250 (`https://daten.gdz.bkg.bund.de/produkte/vg/vg250_ebenen_0101/aktuell/vg250_01-01.utm32s.gpkg.ebenen.zip`)
is generalised for 1:250 000: the outline is within roughly 100 m of the
cadastral boundary – good for the dashed outline, the discovered share and the
download region. Where the LGLN buckets are is described in
[docs/06](06-braunschweig-data.md#where-the-lgln-files-are).

## Pipeline

1. `Tools/cities/vg250_boundary.py`: the outline (ETRS89/UTM 32N → WGS84) and
   the outline grown by 1 km.
2. `Tools/cities/lgln_lod2.py`: the LoD2 tiles intersecting the grown outline,
   extracted with `Tools/berlin/extract_lod2.py`.
3. `Tools/cities/lod2_buildings.py`: each LoD2 footprint becomes a building
   with height source *measured*; `mapquest-import buildings --complete-inside`
   the grown outline, so the town and 1 km around it never need downloads.
   Beyond that, within the download region (2 km around the outline's bounds),
   the app completes tiles from OpenStreetMap on demand like in the other
   cities.
4. `Tools/cities/lgln_terrain.py`: the DGM1 tiles around the town → MQDEM001.

## Result (8 November 2026)

| | |
|---|---|
| Outline | 119.8 km² (official: 119.5 km²), 394 points, two parts |
| LoD2 | 102 874 footprints from 195 tiles (44 tiles around the town without buildings) |
| Buildings | 102 822 (60 536 inside the town limits), all with measured heights; mean 5.7 m; tallest: industrial structures in the south-west (up to 153 m) |
| Database | 9.8 MB, 5.0 MB compressed; 59 complete zoom-14 tiles |
| Terrain | 288 DGM1 tiles → 469 × 548 cells, 58.7–109.6 m (median 71.4 m); Marktplatz 67 m |
| Viewsheds | Marktplatz 31.5 %, Bahnhof forecourt 24.9 %, Vöhrum side street 93.1 % of the 150 m view disk; 40 m above the old town: 2 083 buildings seen, 0.51 km² visible within 724 m |

With the terrain model the line-of-sight layer's ID changes once more
(`berlin-dgm30+braunschweig-dgm30+peine-dgm30`), so it is rebuilt once after
the update.
