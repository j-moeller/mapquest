import XCTest
@testable import MapQuestCore
import MapQuestTestSupport

final class InMemoryDataStoreTests: XCTestCase {
    func testLocationStoreContract() async throws {
        try await DataStoreContract.verifyLocationStore(InMemoryDataStore())
    }

    func testDiscoveredAreaStoreContract() async throws {
        try await DataStoreContract.verifyDiscoveredAreaStore(InMemoryDataStore())
    }

    func testChangeSetAppendKeepsSequentialSemantics() async throws {
        let layer: DiscoveryLayerID = "l"
        let r1 = UUID(), r2 = UUID()
        let p1 = DataStoreContract.makePiece(layer: layer, region: r1, tileX: 1, firstDiscovered: DataStoreContract.start)
        let p2 = DataStoreContract.makePiece(layer: layer, region: r2, tileX: 2, firstDiscovered: DataStoreContract.start)
        let p3 = DataStoreContract.makePiece(layer: layer, region: r1, tileX: 3, firstDiscovered: DataStoreContract.start)

        var combined = DiscoveredAreaChangeSet(layer: layer, upsertedPieces: [p1, p2])
        combined.append(DiscoveredAreaChangeSet(
            layer: layer, regionMerges: [.init(sources: [r1], target: r2)], removedPieceIDs: [p2.id], upsertedPieces: [p3]
        ))

        let sequential = InMemoryDataStore()
        await sequential.apply(DiscoveredAreaChangeSet(layer: layer, upsertedPieces: [p1, p2]))
        await sequential.apply(DiscoveredAreaChangeSet(
            layer: layer, regionMerges: [.init(sources: [r1], target: r2)], removedPieceIDs: [p2.id], upsertedPieces: [p3]
        ))
        let batched = InMemoryDataStore()
        await batched.apply(combined)

        let expected = await sequential.pieces(layer: layer, tiles: nil)
        let actual = await batched.pieces(layer: layer, tiles: nil)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.map(\.regionID), [r2, r1], "p1 relabelled to r2, p3 keeps r1")
    }
}
