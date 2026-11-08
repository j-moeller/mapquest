# MapQuest – Invalidating the discovered-area cache when map data improves

The discovered area is a cache derived from the location samples
(docs/01-literature-review.md, §3). For the **radius layer** the samples are the
only input. The **line-of-sight layer** also depends on *map data*: building
footprints and heights, and terrain. That data changes over time:

* a new city: no building data yet (offline, or nothing downloaded) – the layer
  must still work, with a sensible default;
* buildings are downloaded later (OpenStreetMap via Overpass);
* better data arrives: an official 3D model (LoD2 heights), a newer bundled
  dataset with an app update, a refreshed download.

Whenever the data a cached result was computed from changes, that result is
stale and must be recomputed – but only where it can actually change. This
document reviews the relevant research and derives MapQuest's design.

## 1. The problem in database terms

The discovered area of a layer is a **materialized view** over two relations:
samples *S* and map data *D*:

    A = ⋃_{s ∈ S} reveal(s, D|window(s))

where `window(s)` is the part of the map that can influence `reveal(s)`: for a
viewshed, the square of the view distance around the eye. Two properties make
maintenance non-trivial:

1. **Union is not invertible.** When the result for one sample changes, its old
   contribution cannot be subtracted from `A` – other samples may cover the same
   ground.
2. **Regions are connected components** of `A`. Components can merge (handled by
   union–find, §3.4 of the literature review) but, when area disappears (a newly
   known building hides a street), they can also **split**, which union–find
   cannot express.

## 2. Related work

**Incremental view maintenance.** Blakeley, Larson & Tompa [1] introduced the
incremental maintenance of materialized views; Gupta & Mumick [2] survey the
field. For views that are not invertible, Gupta, Mumick & Subrahmanian [3]
proposed **DRed (Delete and Rederive)**: first delete an over-estimate of
everything that *might* be affected by the change, then re-derive those tuples
from the remaining base data. The alternative, the *counting algorithm* of the
same paper, keeps per-tuple derivation counts; for geometry this would mean
storing every sample's contribution separately (≈ 5 KB per viewshed), which
DRed avoids.

**Build systems.** Mokhov, Mitchell & Peyton Jones [4] classify build systems by
how they decide what to rebuild. A *verifying trace* stores, for every result,
the versions (hashes) of the inputs it was built from; a result is rebuilt iff
one of these versions changed. Storing traces per *input* rather than per
result keeps them small when many results share inputs.

**Data provenance.** Why- and where-provenance [5] and provenance semirings [6]
record which input items a derived item depends on – exactly the information
needed to find stale results when inputs change.

**Tile expiry in web cartography.** Map renderers face the same problem at
city scale: when OpenStreetMap data changes, `osm2pgsql` computes the set of map
tiles touched by the changed geometry (plus a buffer) and marks them dirty for
re-rendering; tiles elsewhere stay cached [7]. The unit of invalidation is the
tile, not an administrative area.

**Visibility.** The region of influence of a visibility computation is bounded
by the maximum view distance; a change of an obstacle can only affect observers
within that distance (cf. the terrain-visibility survey of De Floriani &
Magillo [8]).

**Dynamic connectivity.** Fully dynamic connectivity (edge insertions *and*
deletions) has polylogarithmic algorithms [9], but they are complex; recomputing
components for the few regions touched by an invalidation is simpler and cheap
enough.

**Versions of remote data.** HTTP validators (`ETag`, `Last-Modified`, [10])
identify versions of downloaded resources; a download timestamp or content hash
serves the same purpose for cached map data.

## 3. Alternatives considered

| Approach | Verdict |
|---|---|
| **Rebuild the whole layer** when any data changes | Correct and simple (already used when parameters change), but downloading one 1.5 km tile would recompute every sample in the world. |
| **City limits as invalidation units** (recompute everything inside a city when city data arrives) | Coarse: recomputes a whole city for one changed tile; misses samples just outside the boundary whose view crosses it; cannot describe datasets that overlap or do not follow administrative borders (OSM downloads, border tiles). |
| **Per-sample contributions** (counting algorithm) | Exact and local, but stores every viewshed polygon (tens of MB) and still needs component maintenance. |
| **Per-data-tile versions + DRed over the influence zone** | Local, small metadata, works for any mix of data sources. **Chosen.** |

## 4. Design

### 4.1 Data tiles and versions

Map data is described in **data tiles** – the zoom-14 tiles in which building
data is downloaded and bundled (≈ 1.5 × 1.5 km in Berlin). Every data provider
reports a **version** per data tile:

| Situation | Version |
|---|---|
| No building data available (offline, never downloaded) | `none` |
| Downloaded from OpenStreetMap at time *t* | `download:<t>` |
| From the bundled database built at time *t* | `bundle:<t>` |

Overlapping sources are resolved by the provider, not by the cache: the
`LayeredBuildingCache` lets the bundled Berlin dataset win over downloads and
reports the version of whichever source it uses. The cache only ever sees "the
effective data of tile *t* is version *v*".

### 4.2 The default map where data is missing

Where a data tile has no data (`none`), the line-of-sight layer uses the
**default model**, the radius circle: the revealed area of a sample is

    (viewshed with the known buildings  ∩  tiles with data)
      ∪ (radius circle  ∩  tiles without data)

so entering a city without building data behaves like the 2D layer, and a
sample on the edge of a dataset gets the best of both. Nothing fails offline
any more.

### 4.3 Watermarks: the verifying trace

For each layer, the store keeps the data version every data tile had when the
layer was last made consistent with it (`layer_data_versions`, one row per data
tile – the build-system "trace", stored per input). Results never record
versions individually: the invariant is

> every cached result was computed with the watermarked version of every data
> tile in its window.

A data tile is **stale** when its current version differs from its watermark.
Staleness is detected

* when a download or bundled-data update changes a tile (event),
* at launch, by comparing all watermarks with the providers' current versions
  (catches app updates with new bundled data), and retrying `none` tiles,
* while recording, when a new sample's window contains a tile whose version
  differs from the watermark.

### 4.4 DRed over the influence zone

For a set of stale data tiles *T_d*:

1. **Affected samples** *A*: samples whose window intersects *T_d* (found with
   the samples' tile index, searching *T_d* grown by the maximum view distance).
2. **Delete**: the storage tiles covering the windows of *A*, grown by one tile
   so that the 2 m overlap margins of neighbouring tiles stay exact, are
   cleared. Only here can results change.
3. **Rederive**: every sample whose window intersects the cleared tiles is
   evaluated again with the current data (chronologically, so first-discovery
   times stay right) and merged back – clipped to the cleared tiles, which
   keeps everything outside untouched.
4. **Regions**: connected components are recomputed for the regions that had
   or now have pieces in the cleared tiles. The component containing a region's
   oldest piece keeps the region's ID; split-off parts get new IDs.
5. **Commit**: removals, new pieces, relabelled pieces and the new watermarks
   are written as one atomic change set.

The result is identical to a full rebuild with the new data (verified by tests),
at a cost proportional to the influence zone: a street-level sample has a 150 m
window, so downloading a 1.5 km tile recomputes the samples within ≈ 150 m of it,
not a whole city.

### 4.5 Costs and limits

* Metadata: one row per data tile per layer (Berlin: ≈ 800 rows).
* A high viewpoint (2 km view) makes its whole window dirty when any of its
  ≈ 16 data tiles changes; such samples are rare.
* Model parameters and the terrain model are part of the layer ID; changing them
  creates a new layer, which is rebuilt completely (docs/02-architecture.md).

## References

1. J. A. Blakeley, P.-Å. Larson, F. W. Tompa. *Efficiently updating materialized views.* Proc. ACM SIGMOD 1986, pp. 61–71.
2. A. Gupta, I. S. Mumick. *Maintenance of materialized views: problems, techniques, and applications.* IEEE Data Engineering Bulletin 18(2), 1995, pp. 3–18.
3. A. Gupta, I. S. Mumick, V. S. Subrahmanian. *Maintaining views incrementally.* Proc. ACM SIGMOD 1993, pp. 157–166.
4. A. Mokhov, N. Mitchell, S. Peyton Jones. *Build systems à la carte.* Proc. ACM on Programming Languages 2 (ICFP), 2018, article 79.
5. P. Buneman, S. Khanna, W.-C. Tan. *Why and where: a characterization of data provenance.* Proc. ICDT 2001, LNCS 1973, pp. 316–330.
6. T. J. Green, G. Karvounarakis, V. Tannen. *Provenance semirings.* Proc. ACM PODS 2007, pp. 31–40.
7. osm2pgsql manual, *Expire* (dirty-tile lists for re-rendering after updates). https://osm2pgsql.org/doc/manual.html
8. L. De Floriani, P. Magillo. *Algorithms for visibility computation on terrains: a survey.* Environment and Planning B 30(5), 2003, pp. 709–728.
9. J. Holm, K. de Lichtenberg, M. Thorup. *Poly-logarithmic deterministic fully-dynamic algorithms for connectivity, minimum spanning tree, 2-edge, and biconnectivity.* Journal of the ACM 48(4), 2001, pp. 723–760.
10. R. Fielding, M. Nottingham, J. Reschke. *HTTP Semantics.* RFC 9110, 2022 (validators: §8.8).
