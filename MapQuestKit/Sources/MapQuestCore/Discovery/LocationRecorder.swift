import Foundation

/// When a position fix is evaluated and when it is worth storing.
public struct RecordingPolicy: Hashable, Sendable {
    /// Fixes less accurate than this (metres, 1σ) are ignored.
    public var maximumHorizontalAccuracy: Double
    /// A fix is stored if, for any layer, at least this fraction of its revealed area is new …
    public var minimumNewAreaFraction: Double
    /// … or at least this much area (m²) is new …
    public var minimumNewAreaSquareMeters: Double
    /// … or it closes a gap – fog enclosed by discovered area, like the spot three
    /// overlapping circles leave between them (`DiscoveryEngine.gapFill`) – or
    /// fills at least this much (m²) of gaps. Gaps are often far smaller than the
    /// thresholds above, so without this they would stay black spots for good.
    /// (Slivers of a big gap below this are left to the usual thresholds.)
    public var minimumGapAreaSquareMeters: Double
    /// Which fixes are evaluated at all (`CoverageSampler`): about one per
    /// `sampling.spacing` metres of movement, none while standing still.
    public var sampling: CoverageSampler.Configuration

    public init(
        maximumHorizontalAccuracy: Double = 50,
        minimumNewAreaFraction: Double = 0.1,
        minimumNewAreaSquareMeters: Double = 2_000,
        minimumGapAreaSquareMeters: Double = 25,
        samplingSpacing: Double = 10,
        minimumClimb: Double = 3
    ) {
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
        self.minimumNewAreaFraction = minimumNewAreaFraction
        self.minimumNewAreaSquareMeters = minimumNewAreaSquareMeters
        self.minimumGapAreaSquareMeters = minimumGapAreaSquareMeters
        self.sampling = CoverageSampler.Configuration(
            spacing: samplingSpacing, minimumClimb: minimumClimb, maximumAccuracy: maximumHorizontalAccuracy
        )
    }

    public func isSignificant(_ evaluation: DiscoveryEvaluation) -> Bool {
        evaluation.newAreaSquareMeters > 0
            && (evaluation.newAreaFraction >= minimumNewAreaFraction
                || evaluation.newAreaSquareMeters >= minimumNewAreaSquareMeters)
    }

    /// Whether filling gaps makes a fix worth storing: it closes one, or fills enough.
    public func isSignificant(_ fill: GapFill) -> Bool {
        fill.closedGaps > 0 || fill.filledSquareMeters >= minimumGapAreaSquareMeters
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
    /// Nothing (significantly) new was revealed and nothing was stored. The
    /// evaluations are empty if the sampler skipped the fix (see `CoverageSampler`).
    case alreadyDiscovered([DiscoveryEvaluation])
    /// The fix was stored and merged into every layer.
    case recorded(LocationSample, [DiscoveryUpdate])

    public var isRecorded: Bool {
        if case .recorded = self { return true }
        return false
    }
}

/// The location-tracking component's core: receives every position fix, writes
/// it to the continuous track (if a `TrackWriter` is given), keeps the fixes
/// that reveal new parts of the map as key samples, and feeds those to all
/// discovery engines (2D, 3D, …).
///
/// Every stored sample is merged into every layer, so each layer always equals
/// what a rebuild from the stored samples would produce. If a layer cannot be
/// evaluated (e.g. 3D building data is unavailable offline), the other layers
/// still record and the failed layer is marked stale until it is rebuilt.
public actor LocationRecorder {
    public nonisolated let store: any LocationStore
    /// Receives every valid fix (about one per second).
    public nonisolated let track: TrackWriter?
    public private(set) var engines: [DiscoveryEngine]
    public var policy: RecordingPolicy
    public private(set) var playArea: PlayArea
    /// Layers that missed at least one stored sample and need a rebuild.
    public private(set) var staleLayers: Set<DiscoveryLayerID> = []
    /// The most recent evaluation error per layer.
    public private(set) var lastErrors: [DiscoveryLayerID: String] = [:]
    /// Decides which fixes are evaluated: about one per 10 m of movement.
    private var sampler: CoverageSampler
    /// The evaluations of the last evaluated fix, one per layer that could be evaluated.
    public private(set) var lastEvaluations: [DiscoveryEvaluation] = []
    /// The most recent error writing the track.
    public private(set) var lastTrackError: String?

    public init(
        store: any LocationStore, engines: [DiscoveryEngine], policy: RecordingPolicy = RecordingPolicy(),
        playArea: PlayArea = .world, track: TrackWriter? = nil
    ) {
        self.store = store
        self.engines = engines
        self.policy = policy
        self.playArea = playArea
        self.track = track
        self.sampler = CoverageSampler(configuration: policy.sampling)
    }

    public func setPlayArea(_ area: PlayArea) { playArea = area }
    public func setPolicy(_ policy: RecordingPolicy) {
        if policy.sampling != self.policy.sampling { sampler = CoverageSampler(configuration: policy.sampling) }
        self.policy = policy
    }
    public func setEngines(_ engines: [DiscoveryEngine]) { self.engines = engines }

    /// Processes one position fix.
    public func record(_ sample: LocationSample) async throws -> RecordingOutcome {
        guard sample.hasValidPosition else { return .rejected(.invalidPosition) }
        if let track {
            // The track keeps every fix, everywhere (statistics, heatmaps, time-based views).
            do {
                try await track.append(TrackPoint(sample))
                lastTrackError = nil
            } catch {
                lastTrackError = String(describing: error)
            }
        }
        guard sample.horizontalAccuracy <= policy.maximumHorizontalAccuracy else { return .rejected(.inaccurate) }
        guard playArea.contains(sample.coordinate) else { return .rejected(.outsidePlayArea) }
        // Most fixes reveal nothing the neighbouring ones do not: evaluate only the sampled ones.
        let candidates = sampler.add(sample)
        guard !candidates.isEmpty else { return .alreadyDiscovered([]) }
        var outcome = RecordingOutcome.alreadyDiscovered([])
        for candidate in candidates {
            let result = try await evaluateAndStore(candidate)
            if result.isRecorded || !outcome.isRecorded { outcome = result }
        }
        return outcome
    }

    /// Evaluates the last fix the sampler skipped (e.g. when tracking stops), so
    /// the end of a walk is not lost.
    @discardableResult
    public func finishSampling() async throws -> RecordingOutcome? {
        var outcome: RecordingOutcome?
        for candidate in sampler.finish() {
            outcome = try await evaluateAndStore(candidate)
        }
        return outcome
    }

    /// Evaluates a sampled fix in every layer and stores it if it reveals enough.
    private func evaluateAndStore(_ sample: LocationSample) async throws -> RecordingOutcome {
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
        lastEvaluations = evaluated.map(\.evaluation)
        if evaluated.isEmpty, let failure = failures.first {
            throw failure.error
        }
        guard try await isWorthStoring(evaluated) else {
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

    /// Whether a fix reveals enough in any layer: a large enough share or area, or
    /// it closes or fills gaps in the discovered area (looked for only when the
    /// rest says no, and only where something is new).
    private func isWorthStoring(_ evaluated: [(engine: DiscoveryEngine, evaluation: DiscoveryEvaluation)]) async throws -> Bool {
        if evaluated.contains(where: { policy.isSignificant($0.evaluation) }) { return true }
        for (engine, evaluation) in evaluated where evaluation.newAreaSquareMeters >= GapFill.minimumGapSquareMeters {
            if policy.isSignificant(try await engine.gapFill(of: evaluation)) {
                return true
            }
        }
        return false
    }

    /// What `fillGaps` did.
    public struct GapRepair: Sendable {
        /// Gaps found in all layers.
        public var gaps = 0
        /// Positions of the track that filled gaps, now stored.
        public var storedPositions = 0
        /// Data tiles whose data changed since the layers around them were computed.
        public var staleDataTiles: Set<TileKey> = []
    }

    /// Fills the gaps of the discovered area – fog enclosed by discovered area –
    /// from the track. Before gaps counted, a position in one was not stored when it
    /// revealed little else, so the gap stayed black although you walked through
    /// it; the track still has those positions. Replays the track's positions within
    /// `reach` metres of a gap (the order and sampling of live recording) and stores
    /// those that are worth it now.
    public func fillGaps(
        from points: [TrackPoint], reach: Double, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> GapRepair {
        var repair = GapRepair()
        // Where positions can fill a gap, indexed by storage tile.
        var areas: [TileKey: [WorldRect]] = [:]
        for engine in engines {
            for gap in try await engine.gapBounds() {
                repair.gaps += 1
                let metersPerUnit = WebMercator.metersPerUnit(atWorldY: Double(gap.center.y))
                let area = gap.expanded(by: Int64((reach / metersPerUnit).rounded(.up)))
                for tile in TileRange(covering: area, zoom: DiscoveryGrid.zoom) {
                    areas[tile, default: []].append(area)
                }
            }
        }
        guard !areas.isEmpty else { return repair }
        var sampler = CoverageSampler(configuration: policy.sampling)
        var candidates: [LocationSample] = []
        for point in points {
            let sample = point.sample
            guard sample.hasValidPosition, sample.horizontalAccuracy <= policy.maximumHorizontalAccuracy,
                  playArea.contains(sample.coordinate) else { continue }
            let world = WebMercator.project(sample.coordinate)
            guard areas[TileKey(containing: world, zoom: DiscoveryGrid.zoom)]?.contains(where: { $0.contains(world) }) == true else {
                continue
            }
            candidates += sampler.add(sample)
        }
        candidates += sampler.finish()
        for (index, candidate) in candidates.enumerated() {
            if case .recorded(_, let updates) = try await evaluateAndStore(candidate) {
                repair.storedPositions += 1
                for update in updates { repair.staleDataTiles.formUnion(update.staleDataTiles) }
            }
            progress?(index + 1, candidates.count)
        }
        return repair
    }

    /// Rebuilds every layer from the stored samples. Returns the data tiles whose
    /// data changed while rebuilding (to be refreshed).
    @discardableResult
    public func rebuildAllLayers(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Set<TileKey> {
        let samples = try await store.samples(matching: .all)
        var stale = Set<TileKey>()
        for engine in engines {
            stale.formUnion(try await engine.rebuild(from: samples, progress: progress))
            staleLayers.remove(engine.layer)
        }
        return stale
    }
}
