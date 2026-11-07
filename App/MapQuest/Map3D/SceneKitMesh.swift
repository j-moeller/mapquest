import MapQuestCore
import SceneKit
import UIKit

extension SCNGeometry {
    /// A SceneKit geometry with per-vertex colours from a MapQuest mesh.
    static func make(from mesh: Mesh) -> SCNGeometry {
        let floatSize = MemoryLayout<Float>.size
        let positions = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normals = mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let colors = mesh.colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let indices = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let sources = [
            SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: mesh.vertexCount, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: floatSize, dataOffset: 0, dataStride: 3 * floatSize),
            SCNGeometrySource(data: normals, semantic: .normal, vectorCount: mesh.vertexCount, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: floatSize, dataOffset: 0, dataStride: 3 * floatSize),
            SCNGeometrySource(data: colors, semantic: .color, vectorCount: mesh.vertexCount, usesFloatComponents: true,
                              componentsPerVector: 4, bytesPerComponent: floatSize, dataOffset: 0, dataStride: 4 * floatSize),
        ]
        let element = SCNGeometryElement(
            data: indices, primitiveType: .triangles, primitiveCount: mesh.triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor.white // multiplied with the vertex colours
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
