import MapQuestCore
import SceneKit
import SwiftUI
import UIKit

/// The interactive 3D model of a sight in its entry: its building(s) from Berlin's
/// LoD2 models (roof shapes) in orange, the surrounding buildings (the app's
/// building data) in white, on the label-free map. It turns slowly until touched;
/// drag to rotate, pinch to zoom, two fingers to move.
struct SightModelView: UIViewRepresentable {
    let sight: Sight
    let buildings: CachingBuildingSource
    let baseMap: BaseMapStyle

    func makeCoordinator() -> SightModelScene {
        SightModelScene(sight: sight)
    }

    func makeUIView(context: Context) -> SCNView {
        let scene = context.coordinator
        let view = SCNView(frame: .zero)
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.maximumVerticalAngle = 85
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = SightModelScene.sky
        scene.attach(to: view)
        Task { await scene.load(buildings: buildings, baseMap: baseMap, view: view) }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}

/// Builds the scene of `SightModelView`.
@MainActor
final class SightModelScene: NSObject, UIGestureRecognizerDelegate {
    static let sky = UIColor(red: 0.80, green: 0.87, blue: 0.95, alpha: 1)
    static let wall = RGBA(0.98, 0.92, 0.82)
    static let roof = RGBA(0.93, 0.45, 0.12)
    static let surroundings = RGBA(0.93, 0.93, 0.91)

    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Everything that turns.
    private let turntable = SCNNode()
    private let sight: Sight
    private var isLoaded = false

    init(sight: Sight) {
        self.sight = sight
        super.init()
        scene.background.contents = Self.sky
        let camera = SCNCamera()
        camera.zNear = 0.5
        camera.zFar = 10_000
        camera.fieldOfView = 45
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 120, 220)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 850
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowSampleCount = 8
        sun.light?.shadowRadius = 3
        sun.light?.shadowColor = UIColor(white: 0, alpha: 0.35)
        sun.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4, 0)
        scene.rootNode.addChildNode(sun)
        scene.rootNode.addChildNode(turntable)
    }

    /// Stops the turning as soon as the user touches the model.
    func attach(to view: SCNView) {
        for recognizer in [UIPanGestureRecognizer(target: self, action: #selector(touched(_:))),
                           UIPinchGestureRecognizer(target: self, action: #selector(touched(_:)))] {
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    @objc private func touched(_ recognizer: UIGestureRecognizer) {
        if recognizer.state == .began { turntable.removeAllActions() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// The sight's model, its surroundings and the map under them.
    func load(buildings: CachingBuildingSource, baseMap: BaseMapStyle, view: SCNView) async {
        guard !isLoaded else { return }
        isLoaded = true
        let sight = self.sight
        let model = await Task.detached(priority: .userInitiated) { SightModelScene.bundledModel(sight.id) }.value

        // How much surrounding to show: around the model, at least the sight's extent.
        var extent = Float(max(sight.radius, 40))
        var height: Float = 20
        if let model, model.vertexCount > 0 {
            let bounds = model.bounds
            extent = max(extent, max(abs(bounds.min.x), abs(bounds.max.x), abs(bounds.min.z), abs(bounds.max.z)))
            height = max(height, bounds.max.y)
        }
        let radius = Double(min(max(extent * 2.2, 120), 450))
        let frame = LocalFrame(origin: sight.point)
        let rect = frame.worldRect(halfSize: radius)

        // Surroundings: the app's buildings (bundled for Berlin), without the sight's own.
        let coverage = await buildings.coverage(in: rect)
        let all = coverage.buildings
        let (wall, roof, surroundings) = (Self.wall, Self.roof, Self.surroundings)
        let (sightMesh, contextMesh, ownBuildings) = await Task.detached(priority: .userInitiated) { () -> (Mesh?, Mesh, [Building]) in
            var own: [Building] = []
            var context: [Building] = []
            for building in all {
                let p = frame.local(LoD1MeshBuilder.interiorPoint(of: building))
                guard (p.x * p.x + p.z * p.z).squareRoot() <= radius * 0.98 else { continue }
                if let model, model.footprintContains(x: p.x, z: p.z) {
                    continue
                } else if model == nil, building.footprint.contains(sight.point) {
                    own.append(building)  // no LoD2 model: its block in orange
                } else {
                    context.append(building)
                }
            }
            let style = LoD1MeshBuilder.Style(discovered: surroundings, undiscovered: surroundings, roofBrightness: 1.04)
            let contextMesh = LoD1MeshBuilder.mesh(for: context, frame: frame, style: style) { _ in true }
            return (model?.mesh(wall: wall, roof: roof), contextMesh, own)
        }.value

        if let sightMesh, !sightMesh.isEmpty {
            turntable.addChildNode(node(sightMesh))
        }
        if !ownBuildings.isEmpty {
            let style = LoD1MeshBuilder.Style(discovered: roof, undiscovered: roof)
            let mesh = await Task.detached { LoD1MeshBuilder.mesh(for: ownBuildings, frame: frame, style: style) { _ in true } }.value
            turntable.addChildNode(node(mesh))
            height = max(height, Float(ownBuildings.map(\.height).max() ?? 0))
        }
        if !contextMesh.isEmpty {
            turntable.addChildNode(node(contextMesh))
        }
        if sightMesh == nil && ownBuildings.isEmpty {
            // An open place: a pin at its position.
            let pin = SCNNode(geometry: SCNCone(topRadius: 6, bottomRadius: 0, height: 16))
            pin.geometry?.firstMaterial?.diffuse.contents = UIColor.orange
            pin.position = SCNVector3(0, 10, 0)
            turntable.addChildNode(pin)
        }

        // The ground: the map of the area on a slab.
        let size = CGFloat(2 * radius)
        let slab = SCNBox(width: size, height: 2, length: size, chamferRadius: 0)
        let top = SCNMaterial()
        top.diffuse.contents = UIColor(white: 0.9, alpha: 1)
        let side = SCNMaterial()
        side.diffuse.contents = UIColor(white: 0.55, alpha: 1)
        slab.materials = [side, side, side, side, top, side]  // front, right, back, left, top, bottom
        let ground = SCNNode(geometry: slab)
        ground.position = SCNVector3(0, -1.05, 0)
        turntable.addChildNode(ground)
        Task {
            guard let image = await BaseMapTiles.shared(baseMap).image(of: rect, pixelWidth: 1_024) else { return }
            top.diffuse.contents = UIImage(cgImage: image)
        }

        // Camera: the whole model in view, from the south-east, a little above.
        let distance = max(Double(height) * 2.4, Double(extent) * 3.2, 110)
        let target = SCNVector3(0, height * 0.35, 0)
        cameraNode.position = SCNVector3(Float(distance * 0.55), Float(distance * 0.55), Float(distance * 0.85))
        cameraNode.look(at: target)
        view.defaultCameraController.target = target
        if let light = scene.rootNode.childNodes.first(where: { $0.light?.type == .directional })?.light {
            light.orthographicScale = CGFloat(radius * 1.3)
            light.zFar = CGFloat(radius * 6)
        }
        startTurning()
    }

    /// Turns the model slowly. Synchronous on purpose: in an async context Swift
    /// would pick SceneKit's async `runAction`, which waits for the (endless) action.
    private func startTurning() {
        turntable.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 48)), forKey: "turning")
    }

    private func node(_ mesh: Mesh) -> SCNNode {
        let geometry = SCNGeometry.make(from: mesh)
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.castsShadow = true
        return node
    }

    /// The bundled model of a sight (`sight-<id>.mqm`, raw DEFLATE), if it has one.
    nonisolated static func bundledModel(_ id: String) -> SightModel? {
        guard let url = Bundle.main.url(forResource: "sight-\(id)", withExtension: "mqm"),
              let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? SightModel.decode(data)
    }
}
