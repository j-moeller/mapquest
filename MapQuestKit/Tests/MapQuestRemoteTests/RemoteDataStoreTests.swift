import Foundation
import MapQuestCore
import MapQuestTestSupport
import XCTest
@testable import MapQuestRemote

/// Runs the store contract against a real server (Server/mapquest_server.py + PostgreSQL).
/// Set MAPQUEST_REMOTE_URL and MAPQUEST_REMOTE_TOKEN to enable; skipped otherwise.
final class RemoteDataStoreTests: XCTestCase {
    func makeStore() throws -> RemoteDataStore {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["MAPQUEST_REMOTE_URL"].flatMap(URL.init(string:)),
              let token = environment["MAPQUEST_REMOTE_TOKEN"]
        else { throw XCTSkip("MAPQUEST_REMOTE_URL / MAPQUEST_REMOTE_TOKEN not set") }
        return RemoteDataStore(
            descriptor: DataSourceDescriptor(id: "remote-test", displayName: "Remote test", kind: .remote(baseURL: url, userID: "test")),
            baseURL: url, token: token
        )
    }

    private func clean(_ store: RemoteDataStore) async throws {
        try await store.removeAllSamples()
        for layer in try await store.layers() {
            try await store.removeAllPieces(layer: layer)
        }
    }

    func testLocationStoreContract() async throws {
        let store = try makeStore()
        try await clean(store)
        try await DataStoreContract.verifyLocationStore(store)
    }

    func testTrackStoreContract() async throws {
        let store = try makeStore()
        try await DataStoreContract.verifyTrackStore(store)
    }

    func testDiscoveredAreaStoreContract() async throws {
        let store = try makeStore()
        try await clean(store)
        try await DataStoreContract.verifyDiscoveredAreaStore(store)
        try await clean(store)
    }

    func testRecorderAgainstTheServer() async throws {
        let store = try makeStore()
        try await clean(store)
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: store)
        let recorder = LocationRecorder(store: store, engines: [engine])
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        for i in 0..<120 {
            _ = try await recorder.record(LocationSample(
                latitude: 52.52, longitude: 13.405 + Double(i) * 2 / 67_800, altitude: 40,
                horizontalAccuracy: 5, verticalAccuracy: 3, timestamp: start.addingTimeInterval(Double(i))
            ))
        }
        let local = await engine.snapshot().totalAreaSquareMeters
        // A second client reading the same account sees the same discovered area.
        let reader = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: try makeStore())
        try await reader.loadAll()
        let remote = await reader.snapshot()
        XCTAssertEqual(remote.totalAreaSquareMeters, local, accuracy: 1e-6)
        XCTAssertEqual(remote.regions.count, 1)
        let me = try await store.whoAmI()
        XCTAssertFalse(me.id.isEmpty)
        try await clean(store)
    }

    func testBadTokenIsRejected() async throws {
        let store = try makeStore()
        let bad = RemoteDataStore(descriptor: store.descriptor, baseURL: store.baseURL, token: "wrong")
        do {
            _ = try await bad.sampleCount()
            XCTFail("expected an error")
        } catch let error as RemoteDataStore.RemoteError {
            XCTAssertEqual(error, .http(status: 401, message: "unknown token"))
        }
    }
}
