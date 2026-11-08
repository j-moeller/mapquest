"""Reference server for MapQuest's remote data store (PostgreSQL behind a small REST API).

The iPhone never talks to PostgreSQL directly (no database credentials on the
device); it uses this API with a per-user bearer token. The API mirrors the
`MapQuestDataStore` protocol 1:1 – see docs/04-remote-store.md.

Usage:
  pip install "psycopg[binary]"
  export DATABASE_URL=postgresql://mapquest:secret@localhost/mapquest
  python3 Server/mapquest_server.py migrate                       # apply Server/schema.sql
  python3 Server/mapquest_server.py add-user alice "Alice"        # prints alice's token once
  python3 Server/mapquest_server.py serve --port 8080             # put HTTPS (a reverse proxy) in front
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import secrets
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import psycopg
from psycopg.types.json import Jsonb

SCHEMA = pathlib.Path(__file__).with_name("schema.sql")
MAX_BODY = 64 * 1024 * 1024

_local = threading.local()


def connection() -> psycopg.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None or conn.closed:
        conn = psycopg.connect(os.environ["DATABASE_URL"], autocommit=False)
        with conn.cursor() as cur:
            cur.execute("SET search_path = mapquest")
        conn.commit()
        _local.conn = conn
    return conn


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


class ApiError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status


def number(query: dict, name: str, cast=float):
    values = query.get(name)
    if not values:
        return None
    try:
        return cast(values[0])
    except ValueError as error:
        raise ApiError(HTTPStatus.BAD_REQUEST, f"invalid {name}") from error


def sample_row(sample: dict, owner: str) -> tuple:
    return (
        owner, sample["id"], sample["latitude"], sample["longitude"], sample["altitude"],
        sample["horizontalAccuracy"], sample["verticalAccuracy"], sample["timestamp"],
        sample["tileX"], sample["tileY"],
    )


def sample_json(row) -> dict:
    return {
        "id": str(row[0]).upper(), "latitude": row[1], "longitude": row[2], "altitude": row[3],
        "horizontalAccuracy": row[4], "verticalAccuracy": row[5], "timestamp": row[6],
        "tileX": row[7], "tileY": row[8],
    }


def piece_json(row, layer: str) -> dict:
    return {
        "id": str(row[0]).upper(), "layer": layer, "regionID": str(row[1]).upper(),
        "tileZoom": row[2], "tileX": row[3], "tileY": row[4],
        "geometry": base64.b64encode(bytes(row[5])).decode("ascii"),
        "areaSquareMeters": row[6], "firstDiscovered": row[7], "lastUpdated": row[8],
    }


def tile_filter(query: dict, conditions: list, params: list) -> None:
    bounds = [number(query, n, int) for n in ("minTileX", "maxTileX", "minTileY", "maxTileY")]
    if any(b is not None for b in bounds):
        if any(b is None for b in bounds):
            raise ApiError(HTTPStatus.BAD_REQUEST, "tile filters need minTileX, maxTileX, minTileY and maxTileY")
        conditions.append("tile_x BETWEEN %s AND %s AND tile_y BETWEEN %s AND %s")
        params += bounds


class Handler(BaseHTTPRequestHandler):
    server_version = "MapQuestServer/1"

    # -- plumbing ---------------------------------------------------------

    def log_message(self, format, *args):  # quieter default logging
        if os.environ.get("MAPQUEST_LOG"):
            super().log_message(format, *args)

    def send_json(self, status: HTTPStatus, body) -> None:
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "body too large")
        try:
            return json.loads(self.rfile.read(length) or b"null")
        except json.JSONDecodeError as error:
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid JSON") from error

    def owner(self, cur) -> str:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            raise ApiError(HTTPStatus.UNAUTHORIZED, "missing bearer token")
        cur.execute("SELECT id FROM users WHERE token_sha256 = %s", (token_hash(auth[7:].strip()),))
        row = cur.fetchone()
        if row is None:
            raise ApiError(HTTPStatus.UNAUTHORIZED, "unknown token")
        return row[0]

    def dispatch(self, method: str) -> None:
        url = urlparse(self.path)
        query = parse_qs(url.query)
        route = {
            ("GET", "/v1/samples"): self.get_samples,
            ("PUT", "/v1/samples"): self.put_samples,
            ("DELETE", "/v1/samples"): self.delete_samples,
            ("GET", "/v1/samples/count"): self.count_samples,
            ("GET", "/v1/pieces"): self.get_pieces,
            ("DELETE", "/v1/pieces"): self.delete_pieces,
            ("POST", "/v1/changes"): self.post_changes,
            ("GET", "/v1/layers"): self.get_layers,
            ("GET", "/v1/data-versions"): self.get_data_versions,
            ("PUT", "/v1/track"): self.put_track,
            ("GET", "/v1/track"): self.get_track,
            ("GET", "/v1/track/summary"): self.track_summary,
            ("DELETE", "/v1/track"): self.delete_track,
            ("GET", "/v1/me"): self.get_me,
        }.get((method, url.path))
        conn = None
        try:
            if route is None:
                raise ApiError(HTTPStatus.NOT_FOUND, "no such endpoint")
            conn = connection()
            with conn.cursor() as cur:
                result = route(cur, self.owner(cur), query)
            conn.commit()
            self.send_json(HTTPStatus.OK, result)
        except ApiError as error:
            if conn is not None:
                conn.rollback()
            self.send_json(error.status, {"error": str(error)})
        except (KeyError, TypeError, ValueError, psycopg.DataError) as error:
            if conn is not None:
                conn.rollback()
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": f"invalid request: {error}"})
        except psycopg.Error as error:
            if conn is not None:
                conn.rollback()
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"database error: {error.__class__.__name__}"})

    def do_GET(self):
        self.dispatch("GET")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_POST(self):
        self.dispatch("POST")

    def do_DELETE(self):
        self.dispatch("DELETE")

    # -- endpoints --------------------------------------------------------

    def get_me(self, cur, owner, query):
        cur.execute("SELECT display_name FROM users WHERE id = %s", (owner,))
        return {"id": owner, "displayName": cur.fetchone()[0]}

    def put_samples(self, cur, owner, query):
        samples = self.body()
        if not isinstance(samples, list):
            raise ApiError(HTTPStatus.BAD_REQUEST, "expected a list of samples")
        cur.executemany(
            """INSERT INTO location_samples
                   (owner, id, latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy, "timestamp", tile_x, tile_y)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
               ON CONFLICT (owner, id) DO UPDATE SET
                   latitude = excluded.latitude, longitude = excluded.longitude, altitude = excluded.altitude,
                   horizontal_accuracy = excluded.horizontal_accuracy, vertical_accuracy = excluded.vertical_accuracy,
                   "timestamp" = excluded."timestamp", tile_x = excluded.tile_x, tile_y = excluded.tile_y""",
            [sample_row(s, owner) for s in samples],
        )
        return {"stored": len(samples)}

    def get_samples(self, cur, owner, query):
        conditions, params = ["owner = %s"], [owner]
        tile_filter(query, conditions, params)
        box = [number(query, n) for n in ("minLatitude", "maxLatitude", "minLongitude", "maxLongitude")]
        if all(b is not None for b in box):
            conditions.append("latitude BETWEEN %s AND %s AND longitude BETWEEN %s AND %s")
            params += box
        if (start := number(query, "from")) is not None:
            conditions.append('"timestamp" >= %s')
            params.append(start)
        if (end := number(query, "to")) is not None:
            conditions.append('"timestamp" < %s')
            params.append(end)
        direction = "DESC" if query.get("order", ["asc"])[0] == "desc" else "ASC"
        sql = ("SELECT id, latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy, \"timestamp\", tile_x, tile_y "
               f"FROM location_samples WHERE {' AND '.join(conditions)} ORDER BY \"timestamp\" {direction}, upper(id::text) {direction}")
        if (limit := number(query, "limit", int)) is not None:
            sql += " LIMIT %s"
            params.append(max(limit, 0))
        cur.execute(sql, params)
        return [sample_json(row) for row in cur.fetchall()]

    def count_samples(self, cur, owner, query):
        cur.execute("SELECT count(*) FROM location_samples WHERE owner = %s", (owner,))
        return {"count": cur.fetchone()[0]}

    def delete_samples(self, cur, owner, query):
        cur.execute("DELETE FROM location_samples WHERE owner = %s", (owner,))
        return {"deleted": cur.rowcount}

    def get_pieces(self, cur, owner, query):
        layer = query.get("layer", [None])[0]
        if not layer:
            raise ApiError(HTTPStatus.BAD_REQUEST, "layer is required")
        conditions, params = ["owner = %s", "layer = %s"], [owner, layer]
        tile_filter(query, conditions, params)
        if (zoom := number(query, "zoom", int)) is not None:
            conditions.append("tile_zoom = %s")
            params.append(zoom)
        cur.execute(
            "SELECT id, region_id, tile_zoom, tile_x, tile_y, geometry, area_m2, first_discovered, last_updated "
            f"FROM discovered_pieces WHERE {' AND '.join(conditions)} ORDER BY tile_y, tile_x, upper(id::text)",
            params,
        )
        return [piece_json(row, layer) for row in cur.fetchall()]

    def delete_pieces(self, cur, owner, query):
        layer = query.get("layer", [None])[0]
        if not layer:
            raise ApiError(HTTPStatus.BAD_REQUEST, "layer is required")
        cur.execute("DELETE FROM discovered_pieces WHERE owner = %s AND layer = %s", (owner, layer))
        deleted = cur.rowcount
        cur.execute("DELETE FROM layer_data_versions WHERE owner = %s AND layer = %s", (owner, layer))
        return {"deleted": deleted}

    def post_changes(self, cur, owner, query):
        change = self.body()
        if not isinstance(change, dict) or not change.get("layer"):
            raise ApiError(HTTPStatus.BAD_REQUEST, "expected a change set with a layer")
        cur.execute("SELECT apply_change_set(%s, %s)", (owner, Jsonb(change)))
        return {"applied": True}

    def get_layers(self, cur, owner, query):
        cur.execute("SELECT DISTINCT layer FROM discovered_pieces WHERE owner = %s ORDER BY layer", (owner,))
        return [row[0] for row in cur.fetchall()]

    def put_track(self, cur, owner, query):
        segments = self.body()
        if not isinstance(segments, list):
            raise ApiError(HTTPStatus.BAD_REQUEST, "expected a list of track segments")
        for s in segments:
            cur.execute(
                """INSERT INTO track_segments
                   (owner, id, start_time, end_time, min_x, min_y, max_x, max_y, point_count, data)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (owner, id) DO UPDATE SET
                     start_time = excluded.start_time, end_time = excluded.end_time,
                     min_x = excluded.min_x, min_y = excluded.min_y, max_x = excluded.max_x, max_y = excluded.max_y,
                     point_count = excluded.point_count, data = excluded.data""",
                (owner, s["id"], float(s["start"]), float(s["end"]), int(s["minX"]), int(s["minY"]),
                 int(s["maxX"]), int(s["maxY"]), int(s["pointCount"]), base64.b64decode(s["data"])),
            )
        return {"stored": len(segments)}

    def get_track(self, cur, owner, query):
        conditions, params = ["owner = %s"], [owner]
        if "from" in query or "to" in query:
            conditions.append("end_time >= %s AND start_time <= %s")
            params += [number(query, "from"), number(query, "to")]
        if "minX" in query:
            conditions.append("max_x >= %s AND min_x <= %s AND max_y >= %s AND min_y <= %s")
            params += [number(query, "minX", int), number(query, "maxX", int), number(query, "minY", int), number(query, "maxY", int)]
        cur.execute(
            "SELECT id, start_time, end_time, min_x, min_y, max_x, max_y, point_count, data FROM track_segments WHERE "
            + " AND ".join(conditions) + " ORDER BY start_time, id",
            params,
        )
        return [
            {"id": str(r[0]).upper(), "start": r[1], "end": r[2], "minX": r[3], "minY": r[4], "maxX": r[5], "maxY": r[6],
             "pointCount": r[7], "data": base64.b64encode(bytes(r[8])).decode("ascii")}
            for r in cur.fetchall()
        ]

    def track_summary(self, cur, owner, query):
        cur.execute(
            "SELECT COUNT(*), COALESCE(SUM(point_count), 0), COALESCE(SUM(LENGTH(data)), 0), MIN(start_time), MAX(end_time) "
            "FROM track_segments WHERE owner = %s",
            (owner,),
        )
        count, points, size, first, last = cur.fetchone()
        return {"segmentCount": count, "pointCount": int(points), "byteCount": int(size), "first": first, "last": last}

    def delete_track(self, cur, owner, query):
        cur.execute("DELETE FROM track_segments WHERE owner = %s", (owner,))
        return {"deleted": cur.rowcount}

    def get_data_versions(self, cur, owner, query):
        layer = query.get("layer", [None])[0]
        if not layer:
            raise ApiError(HTTPStatus.BAD_REQUEST, "layer is required")
        cur.execute(
            "SELECT zoom, x, y, version FROM layer_data_versions WHERE owner = %s AND layer = %s ORDER BY zoom, y, x",
            (owner, layer),
        )
        return [{"zoom": z, "x": x, "y": y, "version": v} for z, x, y, v in cur.fetchall()]


def migrate() -> None:
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        conn.execute(SCHEMA.read_text())
    print("schema applied")


def add_user(user_id: str, display_name: str) -> None:
    token = secrets.token_urlsafe(32)
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        conn.execute(
            "INSERT INTO mapquest.users (id, display_name, token_sha256) VALUES (%s, %s, %s) "
            "ON CONFLICT (id) DO UPDATE SET display_name = excluded.display_name, token_sha256 = excluded.token_sha256",
            (user_id, display_name, token_hash(token)),
        )
    print(token)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("migrate")
    user = commands.add_parser("add-user", help="create a user (or a new token) and print the token")
    user.add_argument("id")
    user.add_argument("display_name")
    serve = commands.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    if "DATABASE_URL" not in os.environ:
        sys.exit("DATABASE_URL is not set")
    if args.command == "migrate":
        migrate()
    elif args.command == "add-user":
        add_user(args.id, args.display_name)
    else:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
        print(f"MapQuest server on http://{args.host}:{args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
