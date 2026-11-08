-- MapQuest remote store: PostgreSQL schema (version 2: data watermarks).
-- Mirrors the local SQLite schema (docs/02-architecture.md) with an `owner`
-- column, so one database serves many users. Apply with:
--   psql "$DATABASE_URL" -f Server/schema.sql

CREATE SCHEMA IF NOT EXISTS mapquest;
SET search_path = mapquest;

CREATE TABLE IF NOT EXISTS users (
    id           text PRIMARY KEY,
    display_name text NOT NULL,
    token_sha256 text NOT NULL UNIQUE,          -- SHA-256 of the bearer token (hex)
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS location_samples (
    owner               text NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    id                  uuid NOT NULL,
    latitude            double precision NOT NULL,   -- WGS84 degrees
    longitude           double precision NOT NULL,
    altitude            double precision NOT NULL,   -- metres above mean sea level
    horizontal_accuracy double precision NOT NULL,
    vertical_accuracy   double precision NOT NULL,
    "timestamp"         double precision NOT NULL,   -- Unix seconds (UTC)
    tile_x              integer NOT NULL,            -- zoom-16 tile = spatial index key
    tile_y              integer NOT NULL,
    PRIMARY KEY (owner, id)
);
CREATE INDEX IF NOT EXISTS location_samples_tile ON location_samples (owner, tile_x, tile_y);
CREATE INDEX IF NOT EXISTS location_samples_time ON location_samples (owner, "timestamp");

CREATE TABLE IF NOT EXISTS discovered_pieces (
    owner            text NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    id               uuid NOT NULL,
    layer            text NOT NULL,
    region_id        uuid NOT NULL,
    tile_zoom        integer NOT NULL,
    tile_x           integer NOT NULL,
    tile_y           integer NOT NULL,
    geometry         bytea NOT NULL,               -- PolygonCodec v1, relative to the tile origin
    area_m2          double precision NOT NULL,    -- area inside the exact tile
    first_discovered double precision NOT NULL,    -- Unix seconds
    last_updated     double precision NOT NULL,
    PRIMARY KEY (owner, id)
);
CREATE INDEX IF NOT EXISTS discovered_pieces_tile ON discovered_pieces (owner, layer, tile_x, tile_y);
CREATE INDEX IF NOT EXISTS discovered_pieces_region ON discovered_pieces (owner, layer, region_id);

-- Data watermarks: the map-data version every data tile (zoom 14) had when a
-- layer was last made consistent with it (docs/05-cache-invalidation.md).
CREATE TABLE IF NOT EXISTS layer_data_versions (
    owner   text NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    layer   text NOT NULL,
    zoom    integer NOT NULL,
    x       integer NOT NULL,
    y       integer NOT NULL,
    version text NOT NULL,
    PRIMARY KEY (owner, layer, zoom, x, y)
);

-- Applies a DiscoveredAreaChangeSet atomically: region merges, then removals,
-- then upserts, then data watermarks.
-- `change` is the JSON body of POST /v1/changes (docs/04-remote-store.md).
CREATE OR REPLACE FUNCTION apply_change_set(p_owner text, change jsonb) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    layer_name text := change ->> 'layer';
    merge jsonb;
BEGIN
    FOR merge IN SELECT * FROM jsonb_array_elements(coalesce(change -> 'regionMerges', '[]'::jsonb)) LOOP
        UPDATE discovered_pieces
           SET region_id = (merge ->> 'target')::uuid
         WHERE owner = p_owner AND layer = layer_name
           AND region_id IN (SELECT value::uuid FROM jsonb_array_elements_text(merge -> 'sources'));
    END LOOP;

    DELETE FROM discovered_pieces
     WHERE owner = p_owner AND layer = layer_name
       AND id IN (SELECT value::uuid FROM jsonb_array_elements_text(coalesce(change -> 'removedPieceIDs', '[]'::jsonb)));

    INSERT INTO discovered_pieces
        (owner, id, layer, region_id, tile_zoom, tile_x, tile_y, geometry, area_m2, first_discovered, last_updated)
    SELECT p_owner, (p ->> 'id')::uuid, layer_name, (p ->> 'regionID')::uuid,
           (p ->> 'tileZoom')::integer, (p ->> 'tileX')::integer, (p ->> 'tileY')::integer,
           decode(p ->> 'geometry', 'base64'), (p ->> 'areaSquareMeters')::double precision,
           (p ->> 'firstDiscovered')::double precision, (p ->> 'lastUpdated')::double precision
      FROM jsonb_array_elements(coalesce(change -> 'upsertedPieces', '[]'::jsonb)) AS p
    ON CONFLICT (owner, id) DO UPDATE SET
        layer = excluded.layer, region_id = excluded.region_id, tile_zoom = excluded.tile_zoom,
        tile_x = excluded.tile_x, tile_y = excluded.tile_y, geometry = excluded.geometry,
        area_m2 = excluded.area_m2, first_discovered = excluded.first_discovered,
        last_updated = excluded.last_updated;

    INSERT INTO layer_data_versions (owner, layer, zoom, x, y, version)
    SELECT p_owner, layer_name, (v ->> 'zoom')::integer, (v ->> 'x')::integer, (v ->> 'y')::integer, v ->> 'version'
      FROM jsonb_array_elements(coalesce(change -> 'dataVersions', '[]'::jsonb)) AS v
    ON CONFLICT (owner, layer, zoom, x, y) DO UPDATE SET version = excluded.version;
END;
$$;
