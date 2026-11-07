#include "MQClipper.h"

#include <new>
#include <vector>

#include "clipper2/clipper.h"

using namespace Clipper2Lib;

struct MQPolygons {
    // polygons[i][0] is the outer ring, polygons[i][1...] are holes.
    std::vector<Paths64> polygons;
};

namespace {

Paths64 makePaths(const MQPathsInput &input, size_t minPoints = 3) {
    Paths64 paths;
    paths.reserve(input.pathCount);
    size_t offset = 0;
    for (size_t i = 0; i < input.pathCount; ++i) {
        const size_t count = input.counts[i];
        Path64 path;
        path.reserve(count);
        for (size_t j = 0; j < count; ++j) {
            path.emplace_back(input.coords[2 * (offset + j)], input.coords[2 * (offset + j) + 1]);
        }
        offset += count;
        if (path.size() >= minPoints) {
            paths.push_back(std::move(path));
        }
    }
    return paths;
}

// Flattens a PolyTree into outer rings with their direct holes; islands inside
// holes become polygons of their own.
void collect(const PolyPath64 &node, MQPolygons &out) {
    for (const auto &child : node) {
        // `child` is an outer ring.
        Paths64 polygon;
        polygon.push_back(child->Polygon());
        for (const auto &hole : *child) {
            polygon.push_back(hole->Polygon());
            collect(*hole, out);  // islands inside the hole
        }
        out.polygons.push_back(std::move(polygon));
    }
}

MQPolygons *fromTree(const PolyTree64 &tree) {
    MQPolygons *result = new (std::nothrow) MQPolygons();
    if (result) collect(tree, *result);
    return result;
}

MQPolygons *unionToPolygons(const Paths64 &paths) {
    PolyTree64 tree;
    BooleanOp(ClipType::Union, FillRule::NonZero, paths, Paths64(), tree);
    return fromTree(tree);
}

}  // namespace

extern "C" {

size_t mq_polygons_count(const MQPolygons *polygons) {
    return polygons ? polygons->polygons.size() : 0;
}

size_t mq_polygons_ring_count(const MQPolygons *polygons, size_t polygon) {
    return polygons->polygons[polygon].size();
}

size_t mq_polygons_ring_point_count(const MQPolygons *polygons, size_t polygon, size_t ring) {
    return polygons->polygons[polygon][ring].size();
}

void mq_polygons_copy_ring(const MQPolygons *polygons, size_t polygon, size_t ring, int64_t *out) {
    const Path64 &path = polygons->polygons[polygon][ring];
    for (size_t i = 0; i < path.size(); ++i) {
        out[2 * i] = path[i].x;
        out[2 * i + 1] = path[i].y;
    }
}

void mq_polygons_free(MQPolygons *polygons) {
    delete polygons;
}

MQPolygons *mq_boolean(MQClipType op, MQFillRule fill, MQPathsInput subject, MQPathsInput clip) {
    try {
        PolyTree64 tree;
        BooleanOp(static_cast<ClipType>(op), static_cast<FillRule>(fill), makePaths(subject), makePaths(clip), tree);
        return fromTree(tree);
    } catch (...) {
        return nullptr;
    }
}

MQPolygons *mq_inflate(MQPathsInput paths, double delta, MQJoinType join, MQEndType end,
                       double miterLimit, double arcTolerance) {
    try {
        // Open paths (polylines) are valid with two points.
        const size_t minPoints = end == MQEndPolygon ? 3 : 2;
        Paths64 inflated = InflatePaths(makePaths(paths, minPoints), delta, static_cast<JoinType>(join),
                                        static_cast<EndType>(end), miterLimit, arcTolerance);
        return unionToPolygons(inflated);
    } catch (...) {
        return nullptr;
    }
}

MQPolygons *mq_rect_clip(MQPathsInput paths, int64_t left, int64_t top, int64_t right, int64_t bottom) {
    try {
        // Normalise to non-zero fill first: RectClip works on each path independently.
        Paths64 merged = Union(makePaths(paths), FillRule::NonZero);
        Paths64 clipped = RectClip(Rect64(left, top, right, bottom), merged);
        return unionToPolygons(clipped);
    } catch (...) {
        return nullptr;
    }
}

MQPolygons *mq_simplify(MQPathsInput paths, double epsilon) {
    try {
        Paths64 simplified = SimplifyPaths(makePaths(paths), epsilon, true);
        return unionToPolygons(simplified);
    } catch (...) {
        return nullptr;
    }
}

MQPolygons *mq_triangulate(MQPathsInput paths, int useDelaunay) {
    try {
        Paths64 triangles;
        TriangulateResult rc = Triangulate(makePaths(paths), triangles, useDelaunay != 0);
        if (rc != TriangulateResult::success) return nullptr;
        MQPolygons *result = new (std::nothrow) MQPolygons();
        if (!result) return nullptr;
        result->polygons.reserve(triangles.size());
        for (auto &triangle : triangles) {
            Paths64 polygon;
            polygon.push_back(std::move(triangle));
            result->polygons.push_back(std::move(polygon));
        }
        return result;
    } catch (...) {
        return nullptr;
    }
}

}  // extern "C"
