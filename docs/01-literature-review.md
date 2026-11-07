# MapQuest – Literature review and design decisions

This document reviews the literature and established practice for the three
technical problems at the core of MapQuest, and derives the design decisions
the implementation follows:

1. **Storing location data** so that it is cheap to write, compact, and easy
   to query by location (*"has this position been seen before, or does it
   uncover something new?"*).
2. **Representing the discovered area** (the "fog of war" holes) as polygons
   that merge only when they are adjacent or overlapping, and that can always
   be rebuilt from the location data.
3. **Computing what is visible** from a position in 3D, so that houses block
   the view, the house itself counts as discovered, and higher viewpoints
   reveal more.

Section 6 summarises all decisions in a table. References are listed at
the end. Numbers in square brackets, e.g. [12], point into that list.

---

## 1. Requirements recap

| # | Requirement (from the task description) | Consequence |
|---|---|---|
| R1 | Track continuously, but store only updates that change the map | The *discovery model* decides whether a fix is stored, not the GPS rate |
| R2 | Query location data by location | A spatial index is mandatory |
| R3 | Store latitude, longitude, height, timestamp | 3D samples with time; timeline replay later |
| R4 | Local database first, swappable for a remote one or another user | A repository *protocol* with interchangeable implementations; no backend-specific features in the core |
| R5 | Discovered area as polygons, merged only if adjacent/overlapping | Robust polygon union and connected-component bookkeeping |
| R6 | Discovered area is a cache derivable from location data | Deterministic, order-independent rebuild |
| R7 | 2D: radius around positions; 3D: occlusion by buildings, height aware | Pluggable *discovery models* that produce the revealed area for one sample |
| R8 | Berlin now, the whole world later | A global coordinate system and a global tiling scheme from day one |

---

## 2. Storing location data

### 2.1 What a location fix is

Core Location delivers `CLLocation` objects with WGS84 latitude/longitude,
`altitude` (metres above mean sea level), `ellipsoidalAltitude` (iOS 15+),
`horizontalAccuracy` and `verticalAccuracy` (1σ radii in metres, negative
when invalid), speed, course and a timestamp. Smartphone GNSS in cities
typically reaches 5–15 m horizontally and is markedly worse vertically,
with multipath errors in street canyons. Two consequences:

* Accuracy must be stored with the fix. It is needed to filter fixes and,
  in 3D, to decide whether the height is trustworthy at all.
* Height must be interpreted relative to the ground (terrain), otherwise
  "being on a high point" cannot be distinguished from "being in a hilly
  district" (Section 4.4).

### 2.2 Reducing what is stored

Continuous tracking at 1 Hz produces ~86 000 fixes per day. The
trajectory-compression literature offers several families of reduction
techniques [11, 12, 13]:

* **Geometric line simplification** such as Douglas–Peucker [10] removes
  points that deviate less than ε from a simplified line. It needs the whole
  line (offline) and ignores time.
* **Online/opening-window and dead-reckoning methods** such as
  Meratnia & de By's time-ratio opening window [11] or SQUISH [12] keep the
  spatio-temporal error bounded while streaming.
* **Semantic sampling** keeps fixes that matter to the application, e.g.
  stay points or map-matched events (overview in Zheng [13]).

MapQuest needs neither faithful trajectories nor speeds; it needs exactly
the fixes that **change the discovered area** (R1). This is semantic
sampling with a very cheap, very effective criterion:

> A fix is stored iff the area it would reveal, minus the area that is
> already discovered, exceeds a threshold.

For a revealed disk of radius *R* moving by *d ≪ R*, the newly revealed area
is ≈ 2·R·d. With *R* = 50 m and a threshold of 10 % of the disk area
(785 m²) a new fix is stored about every 8–10 m of *previously unseen* path
and **never** while moving through known territory. Everything a user does
in familiar surroundings – the daily commute, sitting at home – costs zero
storage. Because the criterion works on the discovered area, it is equally
valid for the 3D viewshed model.

### 2.3 Spatial indexing

Answering "what is stored near here?" requires a spatial index. The
classical options are:

| Family | Examples | Properties |
|---|---|---|
| Tree over rectangles | R-tree [1], R\*-tree [2] | Excellent for boxes and points, dynamic; needs engine support (SQLite R\*Tree module, PostGIS GiST) |
| Space partitioning trees | Quadtree [3], k-d tree | Simple, but in-memory structures; awkward to persist |
| Space-filling curves / cell keys | Z-order/Morton [4], Geohash, Google S2 (Hilbert curve on a cube) [6], Uber H3 (hexagons) [7], slippy-map tiles (Web Mercator quadtree) [8] | Map 2D cells to 1D keys that **any** key-value or B-tree store can index |

Samet [5] gives a comprehensive treatment. For MapQuest the decisive
requirement is **R4 – portability across backends**. An R-tree is only
available where the engine provides one (SQLite needs the optional R\*Tree
module, which is not guaranteed to be compiled into every platform's system
SQLite; Firestore, DynamoDB or a plain REST service have none). Cell keys,
by contrast, work in every store that can index an integer or a string;
document databases that do location queries in practice store geohashes
or S2 cell IDs for exactly this reason.

Among cell schemes, **slippy-map tiles** (the Web Mercator quadtree used by
OpenStreetMap, Apple, and Google maps) are the natural fit here: the map
renderer already speaks this projection (MapKit's `MKMapPoint` is a scaled
Web Mercator), tile keys are trivial to compute, the quadtree hierarchy
gives multi-resolution for free, and the projection is conformal so that
circles stay circles. The known area distortion of Web Mercator [9] is
irrelevant for local, city-scale geometry as long as metric quantities
(radii, areas) are converted with the local scale factor 1/cos φ. S2 or H3
would be equally valid globally but add a dependency and a second
projection between storage and rendering.

At zoom 16 a tile is 611 m at the equator and **372 m in Berlin** – small
enough that a 50 m disk touches at most four tiles, large enough that a
city needs only a few thousand tiles.

### 2.4 On-device storage technology

Options on iOS are Core Data/SwiftData, Realm, and SQLite (directly or via
wrappers such as GRDB). Core Data and SwiftData are object-graph frameworks
whose model is tied to Apple's persistence stack; they are a poor fit for a
store that must be swappable with a remote backend and queried by cell key.
SQLite is part of iOS, transactional, well understood, file-based (one
database file per data source/user is trivial), and the same schema maps
1:1 to server databases (PostgreSQL/PostGIS) or to a document store. The
OGC GeoPackage standard [21] shows that SQLite is a mainstream container
for geodata.

### 2.5 Decision – location data

* **SQLite**, one database file per data source (e.g. per user profile).
* Table `location_samples`: latitude, longitude (WGS84 degrees, `REAL`),
  altitude (m above MSL), horizontal and vertical accuracy, timestamp
  (Unix seconds, UTC), and the **zoom-16 tile key** (`tile_x`, `tile_y`)
  as a B-tree indexed spatial bucket. A second index on the timestamp
  serves the planned timeline.
* Fixes are filtered by accuracy and stored only when they reveal new area
  (novelty-driven sampling, Section 2.2).
* All access goes through a `LocationStore` protocol; the SQLite store, an
  in-memory store (tests, previews) and future remote stores are
  interchangeable.

---

## 3. Representing and merging the discovered area

### 3.1 Raster versus vector

There are two fundamentally different ways to represent "where the fog has
been lifted":

**Raster (occupancy/bitmap grids).** Mark cells of a fixed grid as seen,
as in robotic occupancy grids [27]. Fog of World, the best-known app of this
genre, persists its exploration as per-tile bitmaps (as reverse engineered
by the open-source *fog-machine* project). Union is a bitwise OR,
point queries are O(1), and the approach is perfectly robust. Its costs are
a fixed resolution (at 2 m cells, all of Berlin's 891 km² are 223 million
cells, i.e. 28 MB per layer as an uncompressed bitmap), stair-stepped edges
unless the bitmap is re-vectorised, and connected components that must be
found by flood fill across tile borders.

**Vector (polygons).** Store the revealed area as polygons with holes.
This is resolution independent, compact for smooth shapes, maps directly to
map overlays, and is what the task description asks for. Its costs are the
difficulty of *robust* polygon Boolean operations and the growth of vertex
counts as more area is merged.

### 3.2 Polygon Boolean operations and robustness

The classic algorithms are Weiler–Atherton [14] (polygon area sorting),
Vatti's generic scanbeam clipper [15], Greiner–Hormann [16] (simple and
fast, but with known degenerate cases) and the plane-sweep algorithms of
Martínez et al. [17, 18], which handle arbitrary polygons with holes and
self-overlaps in O((n+k) log n).

The practical difficulty is not the asymptotics but numerical robustness:
floating-point predicates can make sweep algorithms produce inconsistent
topology or crash [19]. Two engineering answers have proven themselves:

* **Integer coordinates with snap rounding** [20]. Intersection points are
  rounded to the integer grid in a controlled manner. **Clipper/Clipper2**
  [22] (Vatti-based, Boost licence) follows this approach with 64-bit
  integer coordinates and is used widely in CAD, 3D printing slicers and
  GIS tooling. It also provides polygon offsetting (buffers), rectangle
  clipping, and – since version 2 – triangulation.
* **Exact predicates / overlay snapping** as in JTS/GEOS OverlayNG [23].
  Very robust, but a large C++ dependency.

Re-implementing a robust clipper is a multi-month effort; using Clipper2 is
the established, low-risk choice. Integer coordinates fit our tiling
naturally: Web Mercator scaled to a 2³²×2³² integer world has a resolution
of 9.3 mm at the equator and **5.7 mm in Berlin**, globally.

### 3.3 Keeping unions cheap: tiling

Incremental union of a new disk with *one* big polygon costs O(n log n) in
the size of that polygon. A city-wide region (all streets connected) easily
reaches 10⁶ vertices, so a per-fix union with the whole region would be far
too slow. The standard remedy in web cartography is to **clip geometry into
tiles**, as vector tiles do [25]: each tile stores only the part of the
geometry inside it, so every operation touches a bounded amount of data
(a 50 m disk touches ≤ 4 tiles of 372 m). Two details matter:

* **Overlap margin.** Pieces are clipped to the tile rectangle *grown by a
  small margin* (2 m). Neighbouring tiles therefore overlap slightly, which
  (a) avoids hairline seams when rendering with anti-aliasing, and
  (b) lets adjacency across a tile border be detected inside a single tile.
  Area statistics are computed on the exact (un-grown) tile rectangle so
  nothing is double counted.
* **Pieces.** Within a tile the union result is split into connected
  polygons-with-holes ("pieces"), each stored as one record. Clipper2's
  `PolyTree` output provides the outer/hole hierarchy directly.

### 3.4 Regions: merging only adjacent areas

The task asks for areas to be merged only when they are adjacent or
overlapping; Berlin and Hamburg – or two districts visited with the phone
switched off in between – remain separate. This is the classic
**connected-components** problem, solved incrementally by union–find
(disjoint-set forests) [24, 26]:

* Each piece carries a **region ID**.
* When a new revealed shape *S* is merged, all pieces that intersect *S*
  grown by a tolerance ε (1 m, "close in vicinity") are collected. If none
  exists, *S* starts a new region. Otherwise all touched regions are
  merged into one (relabelling, the "union" step) and *S* joins it.
* Because components of the "touches" relation do not depend on insertion
  order, a rebuild from location data yields the same partition (R6).

Region IDs are UUIDs, so new regions can be created by any client without
coordinating with a server (R4).

### 3.5 Serialisation formats

Standard interchange formats are WKT/WKB (OGC Simple Features [28]),
GeoJSON (RFC 7946 [29]), TWKB, Google's encoded polyline, FlatGeobuf and
Mapbox Vector Tiles [25]. The compact formats share one trick: rings are
stored as **zig-zag encoded deltas in variable-length integers** relative to
the previous vertex. With integer tile-local coordinates this needs ~2–3
bytes per vertex instead of 16 for two doubles. MapQuest stores pieces in
this encoding (documented in `docs/02-architecture.md`) and can export
GeoJSON for interchange and debugging.

### 3.6 Decision – discovered area

* **Vector polygons** in integer Web Mercator world coordinates (2³²
  resolution), processed with **Clipper2** (vendored C++ behind a small C
  interface).
* Geometry is clipped into **zoom-16 tiles with a 2 m overlap margin** and
  stored as connected **pieces** (outer ring + holes) with tile key, region
  ID, area and first/last discovery timestamps, in the **same SQLite
  database** as the location samples.
* **Regions** are connected components under a 1 m tolerance, maintained by
  union–find relabelling on insert.
* The discovered area is organised in **layers**, one per discovery model
  (e.g. `circle-50m` for 2D, `viewshed-v1` for 3D). Each layer is a cache
  that can be deleted and rebuilt from the location samples at any time.

---

## 4. Visibility in 3D

### 4.1 Visibility polygons and isovists

In 2D, the region visible from a point among polygonal obstacles is its
*visibility polygon*. It can be computed by an angular sweep in
O(n log n) [30] (Lee's linear-time algorithm for simple polygons [31] needed
corrections by Joe & Simpson [32]). In architecture and urban morphology,
the same object is the **isovist** [33]; isovist fields and visibility
graphs [34] are standard tools to analyse how much of a city is visible
from where.

### 4.2 Viewsheds on terrain

Adding height turns the problem into a *viewshed* on a digital surface
model. Point *q* is visible from eye *e* if no obstacle on the segment rises
above the line of sight; along a ray this reduces to comparing **slopes**:
the ground at distance *t* with elevation *g(t)* is visible iff
(g(t) − z_e)/t is at least the maximum slope of everything in front of it.
Franklin & Ray [35] compared exact and approximate algorithms (R3, R2,
XDraw) and showed that cheap ray-based methods are accurate enough in
practice; van Kreveld [36] gives an O(n log n) sweep; Haverkort et al. [37]
treat very large terrains.

### 4.3 3D city models

City models are classified by level of detail [38, 39]: **LoD1** is a
footprint extruded to a single height (a "block model"), LoD2 adds roof
shapes. For visibility at street level LoD1 captures the dominant effect –
buildings block what lies behind them – and is available globally from
OpenStreetMap (footprints with `height` / `building:levels` tags) [40].
Berlin additionally publishes official LoD2 models and building heights as
open data (Section 5).

### 4.4 Decision – 3D discovery ("ray casting")

MapQuest uses a **2.5D ray-casting viewshed** on LoD1 buildings:

1. **Eye height.** The eye is at the fix's altitude, converted to height
   above ground with a terrain model, clamped to at least 1.7 m. When the
   vertical accuracy is poor (> 15 m) the user is assumed to be at street
   level, because GNSS height noise would otherwise produce phantom
   "high points".
2. **Maximum distance** grows with eye height (base 150 m at street level,
   +15 m per metre of height, capped at 2 km). The geometric horizon
   (≈ 3.57·√h km) is never the limit in a city; occlusion and haze are.
3. **Rays.** N rays (default 720, i.e. 0.5°) are cast from the eye. Buildings
   are found with a uniform grid and a voxel-style traversal [41]; each
   building crossing a ray yields an entry/exit interval.
4. **Occlusion by slopes** (Section 4.2): walking along the ray, the running
   maximum slope decides whether the ground is visible. A building whose
   wall or roof rises above the current maximum slope is **seen**: its whole
   footprint becomes discovered, and it occludes what lies behind it – fully
   if it is taller than the eye, partially (a "shadow" of length
   b·(z_e − g)/(z_e − h) behind its far edge) if the eye is higher than the
   roof. Tall landmarks behind lower houses remain visible.
5. **Polygon.** The visible ground intervals are turned into a fan of thin
   wedges, united with the seen building footprints using Clipper2, lightly
   simplified, and fed into the same tiled region machinery as the 2D layer.

A viewshed can consist of several disconnected patches (e.g. a square seen
across a lower block). They are processed separately and become separate
regions unless they touch existing discovered area – consistent with the
"merge only when adjacent" rule.

---

## 5. Rendering and data sources

**2D.** MapKit renders the base map; a single world-covering
`MKOverlay` with a custom `MKOverlayRenderer` fills each requested map
rectangle with a translucent dark colour and then *clears* the discovered
pieces intersecting that rectangle. Because pieces are already tiled, each
render call touches only the pieces of the visible tiles; vertices closer
than one screen pixel are skipped at low zoom levels.

**3D.** Apple's MapKit 3D buildings cannot be coloured per building, so the
3D view renders its own LoD1 scene with SceneKit: buildings are extruded
from the same building data used for ray casting, roofs are triangulated
(Clipper2 triangulation), and every building is coloured by whether it has
been discovered. The ground shows the same fog cut-outs as in 2D.

**Data for Berlin.**

* *Base map (2D):* Apple Maps via MapKit; no data has to be shipped.
* *Play area:* the administrative boundary of Berlin (OSM relation 62422)
  and its twelve districts from OpenStreetMap (ODbL), used to restrict
  tracking to Berlin and to compute statistics per district.
* *Buildings (3D):* OpenStreetMap building footprints with `height`,
  `building:levels`, `min_height` (via the Geofabrik Berlin extract);
  missing heights are estimated from the building type. Berlin's official
  LoD2 model and ALKIS building data (Geoportal Berlin, licence
  dl-de/zero-2-0) are a higher-quality alternative that can be imported
  into the same format later.

**Privacy.** Human mobility traces are highly identifying – four
spatio-temporal points suffice to identify 95 % of individuals in a large
mobile dataset [42], see also [43]. Keeping data local by default, storing
only discovery-relevant fixes, and making any remote store an explicit user
choice are therefore deliberate design properties, not just a prototype
shortcut.

---

## 6. Summary of decisions

| Topic | Decision | Main reasons |
|---|---|---|
| Local database | SQLite, one file per data source | Built into iOS, transactional, portable schema |
| Abstraction | `LocationStore` + `DiscoveredAreaStore` protocols, combined as `MapQuestDataStore` | Local/remote/other-user stores are interchangeable (R4) |
| Location sample | lat, lon, altitude, accuracies, timestamp, z16 tile key | 3D + timeline (R3), spatial bucket (R2) |
| Sampling | Store a fix only if it reveals ≥ 10 % new area | Novelty-driven sampling (R1) |
| Spatial index | Slippy-map tile keys (z16) in B-tree indexes | Works in any backend; same projection as MapKit |
| Coordinates | Integer Web Mercator, 2³² world size | Robust geometry, mm precision, global (R8) |
| Polygon engine | Clipper2 (vendored, C shim) | Robust integer Boolean ops, offsets, triangulation |
| Discovered area | Pieces clipped to z16 tiles + 2 m margin, with region IDs | Bounded cost per update, seamless rendering |
| Merging | Union–find relabelling of regions under 1 m tolerance | Merge only adjacent/overlapping areas (R5) |
| Cache semantics | Layers per discovery model, rebuildable from samples | R6, 2D and 3D coexist |
| Geometry encoding | Zig-zag delta varint rings, GeoJSON export | Compact, simple, interchangeable |
| 3D discovery | 2.5D ray casting on LoD1 buildings with slope-based occlusion | Houses block, houses get discovered, height matters (R7) |
| Rendering | MapKit overlay renderer (2D), SceneKit LoD1 scene (3D) | Per-building fog colouring in 3D |

---

## References

1. A. Guttman. *R-trees: A dynamic index structure for spatial searching.* Proc. ACM SIGMOD, 1984, pp. 47–57.
2. N. Beckmann, H.-P. Kriegel, R. Schneider, B. Seeger. *The R\*-tree: An efficient and robust access method for points and rectangles.* Proc. ACM SIGMOD, 1990, pp. 322–331.
3. R. A. Finkel, J. L. Bentley. *Quad trees: A data structure for retrieval on composite keys.* Acta Informatica 4(1), 1974, pp. 1–9.
4. G. M. Morton. *A computer oriented geodetic data base and a new technique in file sequencing.* IBM technical report, 1966.
5. H. Samet. *Foundations of Multidimensional and Metric Data Structures.* Morgan Kaufmann, 2006.
6. Google. *S2 Geometry Library.* https://s2geometry.io
7. I. Brodsky. *H3: Uber's Hexagonal Hierarchical Spatial Index.* Uber Engineering Blog, 2018. https://h3geo.org
8. OpenStreetMap Wiki. *Slippy map tilenames.* https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
9. S. E. Battersby, M. P. Finn, E. L. Usery, K. H. Yamamoto. *Implications of Web Mercator and its use in online mapping.* Cartographica 49(2), 2014, pp. 85–101.
10. D. H. Douglas, T. K. Peucker. *Algorithms for the reduction of the number of points required to represent a digitized line or its caricature.* Cartographica 10(2), 1973, pp. 112–122.
11. N. Meratnia, R. A. de By. *Spatiotemporal compression techniques for moving point objects.* Proc. EDBT 2004, LNCS 2992, pp. 765–782.
12. J. Muckell, J.-H. Hwang, V. Patil, C. T. Lawson, F. Ping, S. S. Ravi. *SQUISH: An online approach for GPS trajectory compression.* Proc. COM.Geo 2011.
13. Y. Zheng. *Trajectory data mining: An overview.* ACM Transactions on Intelligent Systems and Technology 6(3), 2015, article 29.
14. K. Weiler, P. Atherton. *Hidden surface removal using polygon area sorting.* Proc. SIGGRAPH 1977, pp. 214–222.
15. B. R. Vatti. *A generic solution to polygon clipping.* Communications of the ACM 35(7), 1992, pp. 56–63.
16. G. Greiner, K. Hormann. *Efficient clipping of arbitrary polygons.* ACM Transactions on Graphics 17(2), 1998, pp. 71–83.
17. F. Martínez, A. J. Rueda, F. R. Feito. *A new algorithm for computing Boolean operations on polygons.* Computers & Geosciences 35(6), 2009, pp. 1177–1185.
18. F. Martínez, C. Ogayar, J. R. Jiménez, A. J. Rueda. *A simple algorithm for Boolean operations on polygons.* Advances in Engineering Software 64, 2013, pp. 11–19.
19. L. Kettner, K. Mehlhorn, S. Pion, S. Schirra, C. Yap. *Classroom examples of robustness problems in geometric computations.* Computational Geometry 40(1), 2008, pp. 61–78.
20. J. D. Hobby. *Practical segment intersection with finite precision output.* Computational Geometry 13(4), 1999, pp. 199–214.
21. Open Geospatial Consortium. *OGC GeoPackage Encoding Standard* (OGC 12-128r18).
22. A. Johnson. *Clipper2 – Polygon clipping, offsetting and triangulation library.* https://github.com/AngusJohnson/Clipper2 (Boost Software License).
23. M. Davis. *OverlayNG* in JTS Topology Suite / GEOS, 2020. https://locationtech.github.io/jts/
24. B. A. Galler, M. J. Fischer. *An improved equivalence algorithm.* Communications of the ACM 7(5), 1964, pp. 301–303.
25. Mapbox. *Vector Tile Specification, version 2.1.* https://github.com/mapbox/vector-tile-spec
26. R. E. Tarjan. *Efficiency of a good but not linear set union algorithm.* Journal of the ACM 22(2), 1975, pp. 215–225.
27. A. Elfes. *Using occupancy grids for mobile robot perception and navigation.* Computer 22(6), 1989, pp. 46–57.
28. Open Geospatial Consortium. *Simple Feature Access – Part 1: Common Architecture* (OGC 06-103r4).
29. H. Butler, M. Daly, A. Doyle, S. Gillies, S. Hagen, T. Schaub. *The GeoJSON Format.* RFC 7946, 2016.
30. T. Asano, T. Asano, L. Guibas, J. Hershberger, H. Imai. *Visibility of disjoint polygons.* Algorithmica 1, 1986, pp. 49–63.
31. D. T. Lee. *Visibility of a simple polygon.* Computer Vision, Graphics, and Image Processing 22(2), 1983, pp. 207–221.
32. B. Joe, R. B. Simpson. *Corrections to Lee's visibility polygon algorithm.* BIT 27, 1987, pp. 458–473.
33. M. L. Benedikt. *To take hold of space: isovists and isovist fields.* Environment and Planning B 6(1), 1979, pp. 47–65.
34. A. Turner, M. Doxa, D. O'Sullivan, A. Penn. *From isovists to visibility graphs: a methodology for the analysis of architectural space.* Environment and Planning B 28(1), 2001, pp. 103–121.
35. W. R. Franklin, C. K. Ray. *Higher isn't necessarily better: Visibility algorithms and experiments.* Proc. 6th Int. Symposium on Spatial Data Handling, 1994, pp. 751–770.
36. M. van Kreveld. *Variations on sweep algorithms: efficient computation of extended viewsheds and class intervals.* Proc. 7th Int. Symposium on Spatial Data Handling, 1996, pp. 15–27.
37. H. Haverkort, L. Toma, Y. Zhuang. *Computing visibility on terrains in external memory.* ACM Journal of Experimental Algorithmics 13, 2009.
38. G. Gröger, L. Plümer. *CityGML – Interoperable semantic 3D city models.* ISPRS Journal of Photogrammetry and Remote Sensing 71, 2012, pp. 12–33.
39. F. Biljecki, H. Ledoux, J. Stoter. *An improved LOD specification for 3D building models.* Computers, Environment and Urban Systems 59, 2016, pp. 25–37.
40. M. Haklay, P. Weber. *OpenStreetMap: User-generated street maps.* IEEE Pervasive Computing 7(4), 2008, pp. 12–18.
41. J. Amanatides, A. Woo. *A fast voxel traversal algorithm for ray tracing.* Proc. Eurographics 1987, pp. 3–10.
42. Y.-A. de Montjoye, C. A. Hidalgo, M. Verleysen, V. D. Blondel. *Unique in the Crowd: The privacy bounds of human mobility.* Scientific Reports 3, 2013, article 1376.
43. J. Krumm. *A survey of computational location privacy.* Personal and Ubiquitous Computing 13(6), 2009, pp. 391–399.
