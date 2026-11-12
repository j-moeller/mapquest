import CoreLocation
import MapQuestCore
import SceneKit
import SwiftUI

/// Builds and updates the 3D scene: extruded buildings coloured by the
/// line-of-sight layer, a fogged map on the ground, and the user's position.
@MainActor
final class Scene3DController: ObservableObject {
    /// Shown as an overlay while loading or when building data is missing.
    @Published private(set) var status: Scene3DStatus?
    @Published private(set) var buildingCount = 0
    /// Incremented to ask the scene to re-centre on the user.
    @Published private(set) var reloadRequests = 0

    func requestReload() { reloadRequests += 1 }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Half the edge length of the square shown around the centre, metres.
    let halfSize: Double = 700

    private let buildingsNode = SCNNode()
    /// Buildings of captured sights, in gold (capture component).
    private let sightBuildingsNode = SCNNode()
    private let sightsNode = SCNNode()
    private var sightPins: [SightPin] = []
    private var capturedBuildings: Set<Int64> = []
    private let groundNode = SCNNode()
    private let userNode = SCNNode()
    private var frame: LocalFrame?
    private var buildings: [Building] = []
    private var interiorPoints: [Int64: WorldPoint] = [:]
    private var mapImage: UIImage?
    private var renderedVersion = -1
    private var renderedStyle: FogStyle?
    private var generation = 0

    init() {
        let background = UIColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1)
        scene.background.contents = background
        scene.fogColor = background
        scene.fogStartDistance = 900
        scene.fogEndDistance = 2_600

        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 20_000
        camera.fieldOfView = 55
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 420, 520)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        scene.rootNode.addChildNode(sun)

        let marker = SCNSphere(radius: 4)
        marker.firstMaterial?.diffuse.contents = UIColor.systemOrange
        marker.firstMaterial?.emission.contents = UIColor.systemOrange
        userNode.geometry = marker
        userNode.isHidden = true

        scene.rootNode.addChildNode(groundNode)
        scene.rootNode.addChildNode(buildingsNode)
        scene.rootNode.addChildNode(sightBuildingsNode)
        scene.rootNode.addChildNode(sightsNode)
        scene.rootNode.addChildNode(userNode)
    }

    var isLoaded: Bool { frame != nil }

    /// Whether `coordinate` lies far enough from the scene centre to warrant a reload.
    func needsRecentering(on coordinate: GeoCoordinate) -> Bool {
        guard let frame else { return true }
        let p = frame.local(WebMercator.project(coordinate))
        return max(abs(p.x), abs(p.z)) > halfSize * 0.6
    }

    /// Loads buildings and the ground map around `center` and rebuilds the scene.
    func load(
        center: GeoCoordinate, snapshot: DiscoveredAreaSnapshot, version: Int, fogStyle: FogStyle,
        baseMap: BaseMapStyle, source: CachingBuildingSource
    ) async {
        generation += 1
        let token = generation
        let frame = LocalFrame(origin: WebMercator.project(center))
        let rect = frame.worldRect(halfSize: halfSize)
        // Show the fogged ground right away; map and buildings follow when loaded.
        self.frame = frame
        buildings = []
        interiorPoints = [:]
        buildingCount = 0
        mapImage = nil
        status = .loading
        placeSights()
        renderedVersion = -1
        await recolor(snapshot: snapshot, version: version, fogStyle: fogStyle)

        // The map snapshot is applied as soon as it arrives, independently of the buildings.
        Task { [weak self] in
            let image = await GroundTexture.mapImage(for: rect, style: baseMap)
            guard let self, token == self.generation, let image else { return }
            self.mapImage = image
            self.renderedVersion = -1
            await self.recolor(snapshot: snapshot, version: version, fogStyle: fogStyle)
        }
        // Whatever data is available; tiles without data are reported, not fatal.
        let coverage = await source.coverage(in: rect)
        guard token == generation else { return }
        let loaded = coverage.buildings
        let points = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, LoD1MeshBuilder.interiorPoint(of: $0)) })
        }.value
        guard token == generation else { return }
        buildings = loaded
        interiorPoints = points
        buildingCount = loaded.count
        placeSights()
        if coverage.coveredTiles.isEmpty {
            status = .noData
        } else if coverage.coveredTiles.count < coverage.versions.count {
            status = .partialData
        } else {
            status = loaded.isEmpty ? .noBuildings : nil
        }
        guard token == generation else { return }
        renderedVersion = -1
        await recolor(snapshot: snapshot, version: version, fogStyle: fogStyle)
    }

    /// Re-colours buildings and redraws the ground fog after the discovered area changed.
    func recolor(snapshot: DiscoveredAreaSnapshot, version: Int, fogStyle: FogStyle) async {
        guard let frame, version != renderedVersion || fogStyle != renderedStyle else { return }
        renderedVersion = version
        renderedStyle = fogStyle
        let token = generation
        let buildings = self.buildings
        let points = self.interiorPoints
        let golden = capturedBuildings
        let rect = frame.worldRect(halfSize: halfSize)
        let map = mapImage
        let (mesh, goldMesh, ground) = await Task.detached(priority: .userInitiated) {
            let discovered = Set(buildings.filter { b in
                points[b.id].map(snapshot.isDiscovered) ?? false
            }.map(\.id))
            let mesh = LoD1MeshBuilder.mesh(for: buildings.filter { !golden.contains($0.id) }, frame: frame) { discovered.contains($0.id) }
            let goldMesh = LoD1MeshBuilder.mesh(
                for: buildings.filter { golden.contains($0.id) }, frame: frame, style: SightMarkers3D.captureStyle
            ) { _ in true }
            let ground = GroundTexture.compose(map: map, rect: rect, snapshot: snapshot, style: fogStyle)
            return (mesh, goldMesh, ground)
        }.value
        guard token == generation else { return }
        buildingsNode.geometry = mesh.isEmpty ? nil : SCNGeometry.make(from: mesh)
        sightBuildingsNode.geometry = goldMesh.isEmpty ? nil : SCNGeometry.make(from: goldMesh)

        let plane = SCNPlane(width: CGFloat(2 * halfSize), height: CGFloat(2 * halfSize))
        let material = SCNMaterial()
        material.diffuse.contents = ground
        material.lightingModel = .constant
        plane.materials = [material]
        groundNode.geometry = plane
        groundNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) // lie flat, texture top = north
    }

    // MARK: Sights (capture component)

    /// Shows sights in the scene; call `recolor` afterwards (captured buildings turn gold).
    func setSights(_ pins: [SightPin]) {
        guard pins != sightPins else { return }
        sightPins = pins
        placeSights()
    }

    /// Markers for the sights inside the scene; buildings of captured sights.
    private func placeSights() {
        sightsNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let frame else { return }
        var golden: Set<Int64> = []
        for pin in sightPins {
            let p = frame.local(pin.sight.point)
            guard max(abs(p.x), abs(p.z)) <= halfSize else { continue }
            let building = SightMarkers3D.building(at: pin.sight, in: buildings)
            if pin.isCaptured, let building { golden.insert(building.id) }
            let height = Float((building?.height ?? 0) + 24)
            sightsNode.addChildNode(SightMarkers3D.node(for: pin, x: Float(p.x), z: Float(p.z), height: height))
        }
        if golden != capturedBuildings {
            capturedBuildings = golden
            renderedVersion = -1
        }
    }

    /// Moves the position marker (at eye height).
    func updateUser(_ location: CLLocation?, eyeHeight: Double) {
        guard let frame, let location, location.horizontalAccuracy >= 0 else {
            userNode.isHidden = true
            return
        }
        let p = frame.local(WebMercator.project(GeoCoordinate(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude
        )))
        userNode.position = SCNVector3(Float(p.x), Float(eyeHeight), Float(p.z))
        userNode.isHidden = max(abs(p.x), abs(p.z)) > halfSize
    }
}

/// Hosts the SceneKit view.
struct SceneKitView: UIViewRepresentable {
    let controller: Scene3DController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = controller.scene
        view.pointOfView = controller.cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
        view.defaultCameraController.maximumVerticalAngle = 89
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}

/// What the 3D scene reports while it loads or when building data is missing
/// (its text follows the app's language).
enum Scene3DStatus: Equatable {
    case loading
    case noData
    case partialData
    case noBuildings

    var text: String {
        switch self {
        case .loading: return tr("Loading buildings…")
        case .noData: return tr("No building data for this area yet (offline?)")
        case .partialData: return tr("Building data missing for part of this area")
        case .noBuildings: return tr("No buildings in this area")
        }
    }
}

/// Status line and re-centre button of the 3D map, shown in the main overlay.
struct Scene3DOverlay: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @ObservedObject var controller: Scene3DController

    var body: some View {
        let heights = tracker.lastLocation.map { model.viewshedModel.heights(for: LocationSample($0)) }
            ?? (eye: model.viewshedModel.configuration.streetEyeHeight, effective: model.viewshedModel.configuration.streetEyeHeight)
        // The main screen stays clean: the scene's status while it loads, the
        // eye height and view distance only with the developer figures on.
        let showsFigures = model.debug.showsEvaluation
        HStack(alignment: .top) {
            if controller.status != nil || showsFigures {
                VStack(alignment: .leading, spacing: 4) {
                    if let status = controller.status {
                        Text(status.text)
                            .font(.footnote)
                    }
                    if showsFigures {
                        Text(trn(
                            "Eye height {1} m · sight {2} m · {3} building", "Eye height {1} m · sight {2} m · {3} buildings",
                            controller.buildingCount, Formatters.decimal(heights.eye, digits: 0),
                            Formatters.decimal(model.viewshedModel.configuration.viewDistance(eyeHeight: heights.effective), digits: 0),
                            Formatters.number(controller.buildingCount)
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
            Button {
                controller.requestReload()
            } label: {
                Image(systemName: "location.viewfinder")
                    .font(.title3)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(tr("Center on my position"))
        }
    }
}

/// The 3D map scene.
struct Map3DScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tracker: LocationTracker
    @EnvironmentObject private var captures: CaptureModel
    @ObservedObject var controller: Scene3DController

    static let fallbackCenter = GeoCoordinate(latitude: 52.521918, longitude: 13.413215) // Alexanderplatz

    private var center: GeoCoordinate {
        if let location = tracker.lastLocation, location.horizontalAccuracy >= 0 {
            return GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }
        return Self.fallbackCenter
    }

    /// Eye height above the local ground and above the surrounding terrain.
    private var heights: (eye: Double, effective: Double) {
        guard let location = tracker.lastLocation else {
            let street = model.viewshedModel.configuration.streetEyeHeight
            return (street, street)
        }
        return model.viewshedModel.heights(for: LocationSample(location))
    }

    private var eyeHeight: Double { heights.eye }

    var body: some View {
        let layer = model.displayedState(.lineOfSight)
        SceneKitView(controller: controller)
            .ignoresSafeArea()
        .task {
            if !controller.isLoaded { await reload() }
        }
        .onChange(of: controller.reloadRequests) { _, _ in
            Task { await reload() }
        }
        .onChange(of: Self.stamp(layer)) { _, _ in
            Task { await recolor() }
        }
        .onChange(of: model.debug.fogStyle) { _, _ in
            Task { await recolor() }
        }
        // All sights are shown in 3D; captured ones in gold with their building.
        .onChange(of: captures.pins(showingAll: true)) { _, pins in
            controller.setSights(pins)
            Task { await recolor() }
        }
        .onReceive(tracker.$lastLocation) { location in
            controller.updateUser(location, eyeHeight: eyeHeight)
        }
    }

    /// Changes whenever the shown area changes (another period, or a new version).
    private static func stamp(_ layer: LayerState) -> Int {
        layer.identity.hashValue &+ layer.version
    }

    private func reload() async {
        controller.setSights(captures.pins(showingAll: true))
        let layer = model.displayedState(.lineOfSight)
        await controller.load(
            center: center, snapshot: layer.snapshot, version: Self.stamp(layer),
            fogStyle: model.debug.fogStyle, baseMap: model.debug.baseMap, source: model.buildings
        )
        controller.updateUser(tracker.lastLocation, eyeHeight: eyeHeight)
    }

    private func recolor() async {
        let layer = model.displayedState(.lineOfSight)
        await controller.recolor(snapshot: layer.snapshot, version: Self.stamp(layer), fogStyle: model.debug.fogStyle)
    }
}
