// A small C interface to the Clipper2 polygon library, so that Swift can use it
// without C++ interoperability. All coordinates are 64-bit integers.

#ifndef MQ_CLIPPER_H
#define MQ_CLIPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A set of closed paths: `coords` holds x0, y0, x1, y1, … for all paths back to
/// back, `counts[i]` is the number of points of path i.
typedef struct {
    const int64_t *coords;
    const size_t *counts;
    size_t pathCount;
} MQPathsInput;

typedef enum {
    MQClipIntersection = 1,
    MQClipUnion = 2,
    MQClipDifference = 3,
    MQClipXor = 4,
} MQClipType;

typedef enum {
    MQFillEvenOdd = 0,
    MQFillNonZero = 1,
    MQFillPositive = 2,
    MQFillNegative = 3,
} MQFillRule;

typedef enum {
    MQJoinSquare = 0,
    MQJoinBevel = 1,
    MQJoinRound = 2,
    MQJoinMiter = 3,
} MQJoinType;

typedef enum {
    MQEndPolygon = 0,
    MQEndJoined = 1,
    MQEndButt = 2,
    MQEndSquare = 3,
    MQEndRound = 4,
} MQEndType;

/// An opaque list of polygons. Every polygon is a list of rings; ring 0 is the
/// outer boundary, the following rings are its holes. Islands inside holes are
/// separate polygons. Free with `mq_polygons_free`.
typedef struct MQPolygons MQPolygons;

size_t mq_polygons_count(const MQPolygons *polygons);
size_t mq_polygons_ring_count(const MQPolygons *polygons, size_t polygon);
size_t mq_polygons_ring_point_count(const MQPolygons *polygons, size_t polygon, size_t ring);
/// Copies the points of one ring as x, y pairs into `out` (2 × point count values).
void mq_polygons_copy_ring(const MQPolygons *polygons, size_t polygon, size_t ring, int64_t *out);
void mq_polygons_free(MQPolygons *polygons);

/// Boolean operation `subject (op) clip`, returned as polygons with holes.
MQPolygons *mq_boolean(MQClipType op, MQFillRule fill, MQPathsInput subject, MQPathsInput clip);

/// Offsets (inflates for positive `delta`, deflates for negative) paths and
/// returns the non-zero union of the result. `arcTolerance` is the maximum
/// distance between a true arc and its polygon approximation (0 = default).
MQPolygons *mq_inflate(MQPathsInput paths, double delta, MQJoinType join, MQEndType end,
                       double miterLimit, double arcTolerance);

/// Clips closed paths (non-zero fill) to an axis-aligned rectangle.
MQPolygons *mq_rect_clip(MQPathsInput paths, int64_t left, int64_t top, int64_t right, int64_t bottom);

/// Removes vertices closer than `epsilon` to the line through their neighbours
/// (per ring) and re-unions the result (non-zero fill).
MQPolygons *mq_simplify(MQPathsInput paths, double epsilon);

/// Triangulates non-intersecting closed paths (outer rings and holes, even-odd
/// semantics). Every result polygon is a single triangle (one ring of 3 points).
/// Returns NULL if the paths intersect or triangulation fails.
MQPolygons *mq_triangulate(MQPathsInput paths, int useDelaunay);

#ifdef __cplusplus
}
#endif

#endif
