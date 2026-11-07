import Foundation

/// When a position fix is worth storing.
public struct RecordingPolicy: Hashable, Sendable {
    /// Fixes less accurate than this (metres, 1σ) are ignored.
    public var maximumHorizontalAccuracy: Double
    /// A fix is stored if, for any layer, at least this fraction of its revealed area is new …
    public var minimumNewAreaFraction: Double
    /// … or at least this much area (m²) is new.
    public var minimumNewAreaSquareMeters: Double

    public init(
        maximumHorizontalAccuracy: Double = 50,
        minimumNewAreaFraction: Double = 0.1,
        minimumNewAreaSquareMeters: Double = 2_000
    ) {
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
        self.minimumNewAreaFraction = minimumNewAreaFraction
        self.minimumNewAreaSquareMeters = minimumNewAreaSquareMeters
    }

    public func isSignificant(_ evaluation: DiscoveryEvaluation) -> Bool {
        evaluation.newAreaSquareMeters > 0
            && (evaluation.newAreaFraction >= minimumNewAreaFraction
                || evaluation.newAreaSquareMeters >= minimumNewAreaSquareMeters)
    }
}

/// What happened to a position fix.
public enum RecordingOutcome: Sendable {
    public enum RejectionReason: Hashable, Sendable {
        case invalidPosition
        case inaccurate
        case outsidePlayArea
    }

    /// The fix was not considered.
    case rejected(RejectionReason)
    /// The fix revealed (almost) nothing new and was not stored.
    case alreadyDiscovered([DiscoveryEvaluation])
    /// The fix was stored and merged into every layer.
    case recorded(LocationSample, [DiscoveryUpdate])

    public var isRecorded: Bool {
        if case .recorded = self { return true }
        return false
    }
}

/// The location-tracking component's core: receives every position fix, keeps
/// only those that reveal new parts of the map, stores them, and feeds them to
/// all discovery engines (2D, 3D, …).
///
/// Every stored sample is merged into every layer, so each layer always equals
/// what a rebuild from the stored samples would produce. If a layer cannot be
/// evaluated (e.g. 3D building data is unavailable offline), the other layers
/// still record and the failed layer is marked stale until it is rebuilt.
public actor LocationRecorder {
    public nonisolated let store: any LocationStore
    public private(set) var engines: [DiscoveryEngine]
    public var policy: RecordingPolicy
    public private(set) var playArea: PlayArea
    /// Layers that missed at least one stored sample and need a rebuild.
    public private(set) var staleLayers: Set<DiscoveryLayerID> = []
    /// The most recent evaluation error per layer.
    public private(set) var lastErrors: [DiscoveryLayerID: String] = [:]

    public init(store: any LocationStore, engines: [DiscoveryEngine], policy: RecordingPolicy = RecordingPolicy(), playArea: PlayArea = .world) {
        self.store = store
        self.engines = engines
        self.policy = policy
        self.playArea = playArea
    }

    public func setPlayArea(_ area: PlayArea) { playArea = area }
    public func setPolicy(_ policy: RecordingPolicy) { self.policy = policy }
    public func setEngines(_ engines: [DiscoveryEngine]) { self.engines = engines }

    /// Processes one position fix.
    public func record(_ sample: LocationSample) async throws -> RecordingOutcome {
        guard sample.hasValidPosition else { return .rejected(.invalidPosition) }
        guard sample.horizontalAccuracy <= policy.maximumHorizontalAccuracy else { return .rejected(.inaccurate) }
        guard playArea.contains(sample.coordinate) else { return .rejected(.outsidePlayArea) }

        var evaluated: [(engine: DiscoveryEngine, evaluation: DiscoveryEvaluation)] = []
        var failures: [(layer: DiscoveryLayerID, error: Error)] = []
        for engine in engines {
            do {
                evaluated.append((engine, try await engine.evaluate(sample)))
                lastErrors[engine.layer] = nil
            } catch {
                failures.append((engine.layer, error))
                lastErrors[engine.layer] = String(describing: error)
            }
        }
        if evaluated.isEmpty, let failure = failures.first {
            throw failure.error
        }
        guard evaluated.contains(where: { policy.isSignificant($0.evaluation) }) else {
            return .alreadyDiscovered(evaluated.map(\.evaluation))
        }
        try await store.addSamples([sample])
        staleLayers.formUnion(failures.map(\.layer))
        var updates: [DiscoveryUpdate] = []
        for (engine, evaluation) in evaluated {
            updates.append(try await engine.commit(evaluation))
        }
        return .recorded(sample, updates)
    }

    /// Rebuilds every layer from the stored samples.
    public func rebuildAllLayers(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        let samples = try await store.samples(matching: .all)
        for engine in engines {
            try await engine.rebuild(from: samples, progress: progress)
            staleLayers.remove(engine.layer)
        }
    }
}
