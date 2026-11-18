import Foundation
import MapQuestCore

/// The sight packages that come with the app (`Resources/Packages/*.sights.json`,
/// built by Tools/packages/build_packages.py): installed on first launch, and again
/// when the app brings changed ones – except those the user removed (menu › Sight
/// packages offers them again). A lean app brings none: everything is added there.
enum BundledPackages {
    private static let signatureKey = "SightPackages.bundleSignature" // not localized
    private static let removedKey = "SightPackages.removed" // not localized

    static func urls(in bundle: Bundle) -> [URL] {
        (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".sights.json") } // not localized
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func packages(in bundle: Bundle) -> [SightPackage] {
        urls(in: bundle).flatMap { url -> [SightPackage] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? SightPackageFile.decode(data)) ?? []
        }
    }

    /// Installs the bundled packages when they changed since they were last installed
    /// (a new version of the app) or when nothing is installed. An older version never
    /// replaces a newer one (`SightPackageStore.install`).
    static func installNew(from bundle: Bundle, into store: SightPackageStore, defaults: UserDefaults = .standard) {
        let files = urls(in: bundle)
        guard !files.isEmpty else { return }
        let signature = files.map { url in
            "\(url.lastPathComponent):\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
        }.joined(separator: ";")
        let installedFiles = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        let nothingInstalled = !installedFiles.contains { $0.hasSuffix(".sights.json") } // not localized
        guard signature != defaults.string(forKey: signatureKey) || nothingInstalled else { return }
        let removed = Set(defaults.stringArray(forKey: removedKey) ?? [])
        let packages = packages(in: bundle).filter { !removed.contains($0.id) }
        if (try? store.install(packages)) != nil {
            defaults.set(signature, forKey: signatureKey)
        }
    }

    /// A package the user removed: not installed again by itself.
    static func noteRemoved(_ id: String, defaults: UserDefaults = .standard) {
        var removed = defaults.stringArray(forKey: removedKey) ?? []
        if !removed.contains(id) { removed.append(id) }
        defaults.set(removed, forKey: removedKey)
    }

    /// Packages the user added (again).
    static func forgetRemoved(_ ids: [String], defaults: UserDefaults = .standard) {
        let removed = (defaults.stringArray(forKey: removedKey) ?? []).filter { !ids.contains($0) }
        defaults.set(removed, forKey: removedKey)
    }
}

/// What adding a package did, for the message after adding.
struct PackageInstallResult: Identifiable {
    let id: String
    let title: String
    let outcome: SightPackageStore.Outcome

    var message: String {
        switch outcome {
        case .installed: return tr("“{0}” added", title)
        case .updated(let from): return tr("“{0}” updated (it was version {1})", title, from)
        case .reinstalled: return tr("“{0}” was up to date", title)
        case .keptNewer(let installed): return tr("“{0}”: the newer version {1} is kept", title, installed)
        }
    }
}

/// Packages to add, read from a file or link, waiting for the user to confirm.
struct PackageOffer: Identifiable {
    let id = UUID()
    let packages: [SightPackage]
    let data: Data
    /// Where it came from: a file name or a web address.
    let source: String
}

extension SightPackageFile.FileError {
    /// What went wrong, in the app's language.
    var message: String {
        switch self {
        case .notASightPackage: return tr("This file is not a sight package.")
        case .newerFormat: return tr("This sight package needs a newer version of MapQuest.")
        case .unreadable(let detail): return tr("The sight package could not be read: {0}", detail)
        case .invalid(let problems): return tr("The sight package has errors: {0}", problems.joined(separator: "; "))
        }
    }
}

extension SightPackage {
    /// "153 sights · 72 achievements · 343 stations".
    var contentSummary: String {
        var parts: [String] = []
        let sightCount = sights?.count ?? 0
        if sightCount > 0 { parts.append(trn("{0} sight", "{0} sights", sightCount)) }
        let achievementCount = achievements?.count ?? 0
        if achievementCount > 0 { parts.append(trn("{0} achievement", "{0} achievements", achievementCount)) }
        let stationCount = transit?.stations.count ?? 0
        if stationCount > 0 { parts.append(trn("{0} station", "{0} stations", stationCount)) }
        let chapterCount = remembrance?.chapters.count ?? 0
        if chapterCount > 0 { parts.append(trn("{0} chapter of remembrance", "{0} chapters of remembrance", chapterCount)) }
        if parts.isEmpty, let includes, !includes.isEmpty { parts.append(trn("{0} package", "{0} packages", includes.count)) }
        return parts.joined(separator: " · ")
    }
}

extension CaptureModel {
    /// Reads a sight package file to offer it (`offer`); a message if it is none.
    func readPackageFile(_ url: URL) -> Result<PackageOffer, PackageError> {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(PackageError(message: tr("The file could not be opened.")))
        }
        return offer(data, source: url.lastPathComponent)
    }

    /// Downloads a sight package from a web address to offer it.
    func downloadPackage(_ url: URL) async -> Result<PackageOffer, PackageError> {
        guard url.scheme?.lowercased() == "https" else { // not localized
            return .failure(PackageError(message: tr("Sight packages are downloaded from https:// addresses only.")))
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(PackageError(message: tr("The server answered with error {0}.", http.statusCode)))
            }
            return offer(data, source: url.host ?? url.absoluteString)
        } catch {
            return .failure(PackageError(message: tr("The package could not be downloaded: {0}", error.localizedDescription)))
        }
    }

    /// The packages in a file, checked, to show before they are added.
    func offer(_ data: Data, source: String) -> Result<PackageOffer, PackageError> {
        guard data.count <= 64 << 20 else {
            return .failure(PackageError(message: tr("The file is too large for a sight package.")))
        }
        do {
            let packages = try SightPackageFile.decode(data)
            guard !packages.isEmpty else { return .failure(PackageError(message: tr("This file is not a sight package."))) }
            return .success(PackageOffer(packages: packages, data: data, source: source))
        } catch let error as SightPackageFile.FileError {
            return .failure(PackageError(message: error.message))
        } catch {
            return .failure(PackageError(message: error.localizedDescription))
        }
    }

    /// What adding a package would do: replace an installed version, or keep a newer one.
    func installedVersion(of id: String) -> String? {
        library.packages.first { $0.id == id }?.version
    }

    /// Opens a link to the app: a sight package file (from Files, Mail, Safari) or
    /// `mapquest://install?url=https://…` from a website. The packages are shown
    /// before they are added (`packageOffer`).
    func open(_ url: URL) async {
        if url.isFileURL {
            switch readPackageFile(url) {
            case .success(let offer): packageOffer = offer
            case .failure(let error): packageMessage = error.message
            }
            return
        }
        guard url.scheme?.lowercased() == "mapquest", url.host == "install", // not localized
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let address = components.queryItems?.first(where: { $0.name == "url" })?.value, // not localized
              let target = URL(string: address)
        else { return }
        switch await downloadPackage(target) {
        case .success(let offer): packageOffer = offer
        case .failure(let error): packageMessage = error.message
        }
    }
}

/// Why a package could not be read or downloaded.
struct PackageError: Error {
    let message: String
}

extension SightLibrary.Issue {
    /// What the resolution noticed, in the app's language (sights by name where known).
    func message(names: (String) -> String) -> String {
        switch kind {
        case .missingInclude(let id):
            return tr("Builds on “{0}”, which is not installed.", id)
        case .unknownCategory(let category, let sight):
            return tr("“{0}” has the category “{1}”, which no package describes; it is shown as a landmark.", names(sight), category)
        case .unknownChronicle(let chronicle, let sight):
            return tr("“{0}” is dated in the chronicle “{1}”, which no package has.", names(sight), chronicle)
        case .unknownPlace(let place, let container):
            return tr("“{0}” names “{1}”, a place this package and those it builds on do not have.", container, names(place))
        case .unknownEra(let era, let achievement):
            return tr("The achievement “{0}” asks for the era “{1}”, which its chronicles do not have.", achievement, era)
        case .skippedAchievement(let id):
            return tr("The achievement “{0}” finds fewer than two places and is left out.", id)
        case .notRemembrance(let sight, let chapter):
            return tr("The chapter “{0}” names “{1}”, which is not a place of remembrance.", chapter, names(sight))
        case .merged(let sight, let target):
            return tr("“{0}” is the same place as “{1}” in another package and counts as one with it.", sight, names(target))
        }
    }
}
