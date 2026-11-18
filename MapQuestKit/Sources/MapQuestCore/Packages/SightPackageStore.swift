import Foundation

/// The installed sight packages: one JSON file per package in a directory
/// (`<id>.sights.json`), read at launch and resolved into a `SightLibrary`.
public struct SightPackageStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// What installing did with a package.
    public enum Outcome: Equatable, Sendable {
        case installed
        /// Replaced an installed version (`from`).
        case updated(from: String)
        /// The same version was installed already (written again).
        case reinstalled
        /// An older version than the installed one: kept the installed one.
        case keptNewer(installed: String)
    }

    /// The installed packages (unreadable files are skipped and reported in `unreadable`).
    public func installed() -> (packages: [SightPackage], unreadable: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var packages: [SightPackage] = []
        var unreadable: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.lastPathComponent.hasSuffix(".sights.json") {
            do {
                packages += try SightPackageFile.decode(Data(contentsOf: file))
            } catch {
                unreadable.append(file.lastPathComponent)
            }
        }
        return (packages, unreadable)
    }

    /// Installs packages (from one file); an older version never replaces a newer one
    /// unless `allowingOlder`.
    @discardableResult
    public func install(_ packages: [SightPackage], allowingOlder: Bool = false) throws -> [(id: String, outcome: Outcome)] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = Dictionary(installed().packages.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        var results: [(String, Outcome)] = []
        for package in packages {
            let outcome: Outcome
            if let version = current[package.id] {
                if version == package.version {
                    outcome = .reinstalled
                } else if SightPackage.isVersion(package.version, newerThan: version) || allowingOlder {
                    outcome = .updated(from: version)
                } else {
                    results.append((package.id, .keptNewer(installed: version)))
                    continue
                }
            } else {
                outcome = .installed
            }
            try SightPackageFile.encode([package]).write(to: url(of: package.id), options: .atomic)
            results.append((package.id, outcome))
        }
        return results
    }

    /// Removes a package.
    public func remove(_ id: String) throws {
        let file = url(of: id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// The file of a package: its ID made file-name safe.
    public func url(of id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("\(safe).sights.json")
    }
}
