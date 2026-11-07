import Foundation
import MapQuestCore
import MapQuestSQLite

/// The Berlin building database shipped with the app.
///
/// The bundle contains `berlin-buildings.sqlite.deflate` (raw DEFLATE, built by
/// .github/workflows/berlin-buildings.yml). It is unpacked once into Application
/// Support and again whenever the bundled file changes (app update).
enum BundledBuildings {
    private static let markerKey = "BundledBuildings.marker"

    /// Opens the unpacked database, unpacking it first if needed. Runs off the main thread.
    static func prepare(in directory: URL, bundle: Bundle = .main) -> SQLiteBuildingStore? {
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent("berlin.sqlite")
        let compressed = bundle.url(forResource: "berlin-buildings.sqlite", withExtension: "deflate")
        let plain = bundle.url(forResource: "berlin-buildings", withExtension: "sqlite")
        guard let source = compressed ?? plain else {
            return fileManager.fileExists(atPath: target.path) ? try? SQLiteBuildingStore(fileURL: target) : nil
        }
        let size = (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        let marker = "\(source.lastPathComponent):\(size)"
        if !fileManager.fileExists(atPath: target.path) || UserDefaults.standard.string(forKey: markerKey) != marker {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let partial = target.appendingPathExtension("partial")
                try? fileManager.removeItem(at: partial)
                if source == compressed {
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    let unpacked = try (data as NSData).decompressed(using: .zlib) as Data
                    try unpacked.write(to: partial)
                } else {
                    try fileManager.copyItem(at: source, to: partial)
                }
                for suffix in ["", "-wal", "-shm"] {
                    try? fileManager.removeItem(at: URL(fileURLWithPath: target.path + suffix))
                }
                try fileManager.moveItem(at: partial, to: target)
                UserDefaults.standard.set(marker, forKey: markerKey)
            } catch {
                return nil
            }
        }
        return try? SQLiteBuildingStore(fileURL: target)
    }
}
