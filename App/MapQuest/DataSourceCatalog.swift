import Foundation
import MapQuestCore
import MapQuestRemote
import MapQuestSQLite

/// A data source the app can show: the user's own data, another user's data,
/// a demo dataset, or (later) a remote service.
struct DataProfile: Codable, Hashable, Identifiable {
    var descriptor: DataSourceDescriptor
    /// Whether the app records the device's positions into this data source.
    /// Only the user's own profile records; other profiles are view-only.
    var recordsLocations: Bool

    var id: String { descriptor.id }

    /// The name shown: the app's own data sources in the app's language (their stored
    /// `displayName` stays English), other sources as stored.
    var name: String {
        switch id {
        case DataSourceCatalog.ownProfileID: return tr("My discoveries")
        case DataSourceCatalog.sandboxProfileID: return tr("Sandbox (testing)")
        case BerlinData.demoProfileID: return tr("Demo explorer")
        default: return descriptor.displayName
        }
    }
}

enum DataSourceError: LocalizedError {
    case missingToken

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return tr("The access token of this remote data source is missing. Add the data source again.")
        }
    }
}

/// Knows which data sources exist and opens them. Local databases live in
/// Application Support/MapQuest/DataSources, one SQLite file per profile.
final class DataSourceCatalog {
    static let ownProfileID = "me"
    /// A recording profile for experiments (test positions, debug settings).
    static let sandboxProfileID = "sandbox"

    let directory: URL
    private let defaults: UserDefaults
    private static let profilesKey = "DataSourceCatalog.profiles"
    private static let selectedKey = "DataSourceCatalog.selected"

    private(set) var profiles: [DataProfile]

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        directory = support.appendingPathComponent("MapQuest/DataSources", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = defaults.data(forKey: Self.profilesKey),
           let stored = try? JSONDecoder().decode([DataProfile].self, from: data), !stored.isEmpty {
            profiles = stored
        } else {
            profiles = []
        }
        if !profiles.contains(where: { $0.id == Self.ownProfileID }) {
            profiles.insert(DataProfile(
                descriptor: DataSourceDescriptor(
                    id: Self.ownProfileID, displayName: "My discoveries", kind: .localDatabase(path: "me.sqlite") // not localized: stored; shown as `name`
                ),
                recordsLocations: true
            ), at: 0)
            save()
        }
        if !profiles.contains(where: { $0.id == Self.sandboxProfileID }) {
            profiles.append(DataProfile(
                descriptor: DataSourceDescriptor(
                    id: Self.sandboxProfileID, displayName: "Sandbox (testing)", kind: .localDatabase(path: "sandbox.sqlite") // not localized: stored; shown as `name`
                ),
                recordsLocations: true
            ))
            save()
        }
    }

    var selectedProfileID: String {
        get { defaults.string(forKey: Self.selectedKey) ?? Self.ownProfileID }
        set { defaults.set(newValue, forKey: Self.selectedKey) }
    }

    var selectedProfile: DataProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    /// Adds (or replaces) a profile.
    func upsert(_ profile: DataProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    /// Creates a new, empty local view-only profile (e.g. to import a friend's data).
    func addLocalProfile(named name: String) -> DataProfile {
        let id = "local-\(UUID().uuidString.prefix(8).lowercased())"
        let profile = DataProfile(
            descriptor: DataSourceDescriptor(id: id, displayName: name, kind: .localDatabase(path: "\(id).sqlite")),
            recordsLocations: false
        )
        upsert(profile)
        return profile
    }

    /// Opens the store behind a profile.
    func openStore(for profile: DataProfile) throws -> any MapQuestDataStore {
        switch profile.descriptor.kind {
        case .localDatabase(let path):
            return try SQLiteDataStore(fileURL: databaseURL(for: path), descriptor: profile.descriptor)
        case .inMemory:
            return InMemoryDataStore(descriptor: profile.descriptor)
        case .remote(let baseURL, _):
            guard let token = Keychain.get(profile.id) else { throw DataSourceError.missingToken }
            return RemoteDataStore(descriptor: profile.descriptor, baseURL: baseURL, token: token)
        }
    }

    /// Checks a MapQuest server and token, then adds it as a data source.
    /// - Parameter records: whether this device records its positions into the account.
    func addRemoteProfile(baseURL: URL, token: String, records: Bool) async throws -> DataProfile {
        let probe = RemoteDataStore(
            descriptor: DataSourceDescriptor(id: "probe", displayName: "probe", kind: .remote(baseURL: baseURL, userID: "")),
            baseURL: baseURL, token: token
        )
        let me = try await probe.whoAmI()
        let host = baseURL.host ?? baseURL.absoluteString
        let profile = DataProfile(
            descriptor: DataSourceDescriptor(
                id: "remote-\(host)-\(me.id)", displayName: "\(me.displayName) (\(host))",
                kind: .remote(baseURL: baseURL, userID: me.id)
            ),
            recordsLocations: records
        )
        Keychain.set(token, for: profile.id)
        upsert(profile)
        return profile
    }

    /// Resolves a relative database path inside the data source directory
    /// (the app container path changes between installs).
    func databaseURL(for path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
    }
}
