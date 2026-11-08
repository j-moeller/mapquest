# MapQuest – Remote store (PostgreSQL)

The app's data sources are interchangeable (`MapQuestDataStore`). Besides the
local SQLite databases there is a remote store backed by **PostgreSQL**.

## Why an API in front of PostgreSQL

The iPhone does not connect to PostgreSQL directly: database credentials on
a phone cannot be kept secret, and per-user isolation would need one database
role per user. Instead a small REST API (`Server/mapquest_server.py`) holds the
database connection and maps a per-user **bearer token** to an `owner`. Every
endpoint corresponds to one `MapQuestDataStore` method, so the Swift client
(`RemoteDataStore`, product `MapQuestRemote`) is a thin translation layer and
passes the same contract tests as the local stores.

```
iPhone ──HTTPS + Bearer token──▶ mapquest_server.py ──▶ PostgreSQL (schema mapquest)
```

## Schema

`Server/schema.sql` mirrors the SQLite schema with an `owner` column in every
primary key and index: `users`, `location_samples`, `discovered_pieces`
(geometry as `bytea` in the same PolygonCodec format), and the PL/pgSQL
function `apply_change_set(owner, change jsonb)`, which applies a
`DiscoveredAreaChangeSet` atomically (merges → removals → upserts). Tokens are
stored as SHA-256 hashes. PostGIS is not required; a geometry column for
spatial SQL analysis could be added later without changing the API.

## API (version 1)

All requests carry `Authorization: Bearer <token>`. Bodies and responses are
JSON. Timestamps are Unix seconds, UUIDs upper-case strings, `geometry` is the
base64-encoded PolygonCodec blob relative to the tile origin.

| Method and path | Store method | Notes |
|---|---|---|
| `GET /v1/me` | – | `{id, displayName}` of the token's user |
| `PUT /v1/samples` | `addSamples` | body: `[Sample]`, upsert by `id` |
| `GET /v1/samples` | `samples(matching:)` | `minTileX/maxTileX/minTileY/maxTileY`, `minLatitude/…`, `from`, `to`, `order=asc\|desc`, `limit` |
| `GET /v1/samples/count` | `sampleCount` | `{count}` |
| `DELETE /v1/samples` | `removeAllSamples` | |
| `GET /v1/pieces?layer=…` | `pieces(layer:tiles:)` | optional tile range and `zoom` |
| `POST /v1/changes` | `apply(_:)` | body: change set, atomic |
| `DELETE /v1/pieces?layer=…` | `removeAllPieces(layer:)` | also deletes the layer's data watermarks |
| `GET /v1/layers` | `layers()` | `[String]` |
| `GET /v1/data-versions?layer=…` | `dataVersions(layer:)` | `[DataVersion]` (docs/05-cache-invalidation.md) |

```json
Sample: {"id": "…", "latitude": 52.52, "longitude": 13.41, "altitude": 36.0,
         "horizontalAccuracy": 5, "verticalAccuracy": 3, "timestamp": 1760000000.5,
         "tileX": 35207, "tileY": 21490}
Piece:  {"id": "…", "layer": "circle-50m", "regionID": "…", "tileZoom": 16, "tileX": 35207,
         "tileY": 21490, "geometry": "AQEE…", "areaSquareMeters": 812.4,
         "firstDiscovered": 1760000000, "lastUpdated": 1760000100}
Change: {"layer": "circle-50m", "regionMerges": [{"sources": ["…"], "target": "…"}],
         "removedPieceIDs": ["…"], "upsertedPieces": [Piece], "dataVersions": [DataVersion]}
DataVersion: {"zoom": 14, "x": 8802, "y": 5373, "version": "bundle:1760000000"}
```

Errors: HTTP status with `{"error": "…"}` (401 for missing or unknown tokens).

## Running a server

```bash
cd Server && POSTGRES_PASSWORD=… docker compose up -d
```

```bash
docker compose exec api python mapquest_server.py add-user alice "Alice"
```

The second command prints Alice's token once. Without Docker:
`pip install "psycopg[binary]"`, set `DATABASE_URL`, then run
`python3 Server/mapquest_server.py migrate`, `add-user …` and `serve`. Always put
an HTTPS reverse proxy in front of the server (iOS App Transport Security
requires HTTPS for non-local hosts anyway).

In the app: *Settings › Add remote data source…*, enter the server URL and the
token (stored in the Keychain). Choose whether this iPhone records into the
account or only views it (e.g. a friend's account).

## Testing

`MapQuestKit/Tests/MapQuestRemoteTests` runs the store contract tests and a
recorder round trip (one client writes, a second one reads the same account)
against a live server when `MAPQUEST_REMOTE_URL` and `MAPQUEST_REMOTE_TOKEN`
are set. CI's Linux job starts PostgreSQL 16 as a service container plus the
server and runs them on every push. The Docker files are not exercised by CI.

## Limitations

* Recording into a remote account needs connectivity for every stored
  position; an offline-first design (record locally, sync change sets later)
  is the natural next step – the change sets already are the sync unit.
* The reference server is single-process Python; for many users run it
  behind a process manager or port the nine endpoints to any backend.
