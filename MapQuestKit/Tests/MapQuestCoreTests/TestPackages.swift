import Foundation
@testable import MapQuestCore

/// MapQuest's own sight packages (`Packages/<city>.sights.json`), resolved once for the tests.
enum TestPackages {
    static let directory = BraunschweigDataTests.root
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages")

    static func packages(_ city: String) throws -> [SightPackage] {
        try SightPackageFile.decode(Data(contentsOf: directory.appendingPathComponent("\(city).sights.json")))
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var libraries: [String: SightLibrary] = [:]
    }
    private static let cache = Cache()

    /// The packages of one or more cities, resolved.
    static func library(_ cities: String...) throws -> SightLibrary {
        let key = cities.joined(separator: "+")
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let library = cache.libraries[key] { return library }
        let library = SightLibrary(packages: try cities.flatMap { try packages($0) })
        cache.libraries[key] = library
        return library
    }

    static func berlin() throws -> SightLibrary { try library("berlin") }
    static func braunschweig() throws -> SightLibrary { try library("braunschweig") }

    static func chronicle(_ id: String) throws -> Chronicle {
        let library = try library("berlin", "braunschweig")
        guard let chronicle = library.chronicles[id] else { throw CocoaError(.fileNoSuchFile) }
        return chronicle
    }
}
