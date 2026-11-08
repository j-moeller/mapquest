# MapQuest – Braunschweig data

Braunschweig is the second bundled city. Its data is built by
`Tools/cities/build_city.sh` and committed to
`App/MapQuest/Resources/Braunschweig/`. The app finds it by name
(`App/MapQuest/Cities.swift`); every file is optional.

```bash
Tools/cities/build_city.sh --id braunschweig --name Braunschweig --admin-level 6 --bbox 10.30,52.12,10.75,52.42 --viewshed "Burgplatz (street)@52.26420,10.52360"
```

The script works for any city in Lower Saxony (outline from OSM by name and
`admin_level`; LGLN covers the whole state). It needs Python with
`osmium lxml pyproj shapely numpy rasterio`, `sqlite3`, a Swift toolchain,
`osmium-tool` for the Geofabrik download (or `--osm FILE` with an existing
extract) and network access to `download.geofabrik.de` and LGLN's buckets.

| Data | Source | Licence | File |
|---|---|---|---|
| City outline | OpenStreetMap: administrative boundary "Braunschweig", admin_level 6 (Geofabrik extract of Lower Saxony) | ODbL 1.0 | `braunschweig-boundary.geojson` |
| Districts | OpenStreetMap: the Stadtbezirke (admin_level 9, else 10) inside the city | ODbL 1.0 | `braunschweig-districts.geojson` |
| Building footprints | OpenStreetMap (Geofabrik extract), `Tools/berlin/extract_buildings.py` | ODbL 1.0 | `braunschweig-buildings.sqlite.deflate` |
| Building heights | LGLN OpenGeoData *3D-Gebäudemodelle LoD2* (CityGML, 1 km tiles, ETRS89/UTM 32N), matched to the OSM footprints like Berlin's (`Tools/berlin/apply_lod2_heights.py`) | Datenlizenz Deutschland – Namensnennung – 2.0 | (in the building database) |
| Terrain | LGLN OpenGeoData *DGM1* (GeoTIFF, 1 m, 1 km tiles), averaged to 25 m and resampled to a ≈ 30 m grid | Datenlizenz Deutschland – Namensnennung – 2.0 | `braunschweig-terrain.dem` |

Attribution: © OpenStreetMap contributors; © LGLN – Landesamt für
Geoinformation und Landesvermessung Niedersachsen (dl-de/by-2-0).

## Where the LGLN files are

LGLN's OpenGeoData portal is a web application; its files lie in public object
storage buckets:

* LoD2: `https://lod2.s3.eu-de.cloud-object-storage.appdomain.cloud/LoD2_32_<E km>_<N km>_1_ni.gml`
  (CityGML 2.0; an older index with download links is
  `https://single-datasets.opengeodata.lgln.niedersachsen.de/pro-download-indices/lod2/lgln-opengeodata-lod2.geojson`).
* DGM1: `https://dgm1.s3.eu-de.cloud-object-storage.appdomain.cloud/L<lot>/<Vollkacheln|Randkacheln|…>/dgm1_32_<E km>_<N km>_1_ni_<year>.tif`
  (found by listing the bucket; the newest year of a tile wins).

## Pipeline

1. Cut Braunschweig out of the Lower Saxony extract (`osmium extract`, complete
   boundary relations).
2. `Tools/cities/extract_osm_areas.py`: outline and districts, simplified to 2 m.
3. `Tools/berlin/extract_buildings.py`: OSM footprints.
4. `Tools/cities/lgln_lod2.py`: the LoD2 tiles intersecting the outline,
   downloaded six at a time, extracted with `Tools/berlin/extract_lod2.py`
   (any CityGML version, source CRS EPSG:25832) and deleted again.
5. `apply_lod2_heights.py` and `mapquest-import buildings --complete-inside …`:
   the SQLite building database, zoom-14 tiles inside the outline marked
   complete; then compressed (raw DEFLATE).
6. `Tools/cities/lgln_terrain.py`: the DGM1 tiles around the city → MQDEM001.

Steps 4 and 6 are best effort (the script carries on without them): without them the buildings keep their OSM
heights (tags, levels, estimates) and the city has no terrain model – fixes
there then count as street level (docs/02-architecture.md, Cities).

## Result (run of 8 November 2026)

| | |
|---|---|
| Outline | 192.5 km² |
| Districts | 12 Stadtbezirke (admin_level 9), tiling the city |
| OSM buildings | 182 827 in the extract (71 197 inside the city, the rest around it, so the city edges are covered) |
| LoD2 | 201 189 footprints from 223 tiles (25 tiles without buildings); **92.0 %** of the buildings inside the city get measured heights (Berlin: 79.6 %) |
| Tallest | Funkturm Broitzem 154 m, St. Andreas 94.5 m, St. Katharinen 72.9 m, St. Petri 70.7 m |
| Database | 16.9 MB, 8.8 MB compressed; 60 complete zoom-14 tiles |
| Terrain | 378 DGM1 tiles → 670 × 549 cells, 58.5–125.4 m (median 80.2 m); Burgplatz 71 m |
| Viewsheds | Burgplatz 43 %, Altstadtmarkt 26 %, Schlossplatz 66 %, Hauptbahnhof forecourt 93 % of the 150 m view disk |

With the terrain model the line-of-sight layer's ID changes (the terrain
identifier becomes `berlin-dgm30+braunschweig-dgm30`), so it is rebuilt once
after the update.

## Demo

The demo explorer's track (`Tools/berlin/make_demo_data.py`) includes a day
trip through Braunschweig's old town on 24 October 2026.
