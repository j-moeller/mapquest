import MapQuestCore
import SwiftUI
import UniformTypeIdentifiers

/// Menu › Sight packages: the installed packages by region – what each brings, what
/// it builds on and what did not resolve – and adding packages from a file or a link,
/// or those that come with the app. Packages are JSON files (docs/09-sight-packages.md);
/// anyone can make them.
struct SightPackagesView: View {
    @EnvironmentObject private var captures: CaptureModel
    @State private var choosesFile = false
    @State private var asksLink = false
    @State private var link = ""
    @State private var isDownloading = false
    @State private var offer: PackageOffer?
    @State private var message: String?

    var body: some View {
        List {
            if captures.library.packages.isEmpty {
                Section {
                    Text(tr("No sight packages are installed. Add one from a file or a link: its sights, achievements and places of remembrance then appear on the map and in the list."))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.packages) { package in
                        NavigationLink {
                            SightPackageDetailView(packageID: package.id)
                        } label: {
                            PackageRow(package: package, warnings: captures.library.issues(of: package.id).count)
                        }
                    }
                } header: {
                    Text(group.name)
                }
            }
            if !captures.unreadablePackages.isEmpty {
                Section {
                    ForEach(captures.unreadablePackages, id: \.self) { file in
                        Label(file, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(tr("Could not be read"))
                } footer: {
                    Text(tr("These files are not valid sight packages (any more). Add the package again."))
                }
            }
            let bundled = captures.availableBundledPackages
            if !bundled.isEmpty {
                Section {
                    ForEach(bundled) { package in
                        HStack {
                            PackageRow(package: package, warnings: 0)
                            Button(tr("Add")) { captures.installBundled([package]) }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text(tr("Comes with the app"))
                }
            }
            Section {
                Button {
                    choosesFile = true
                } label: {
                    Label(tr("Add from a file…"), systemImage: "doc.badge.plus")
                }
                Button {
                    link = ""
                    asksLink = true
                } label: {
                    if isDownloading {
                        Label(tr("Downloading…"), systemImage: "arrow.down.circle")
                    } else {
                        Label(tr("Add from a link…"), systemImage: "link.badge.plus")
                    }
                }
                .disabled(isDownloading)
            } footer: {
                Text(tr("A sight package is a JSON file (.sights.json) with sights, their entries and history, achievements and places of remembrance – from MapQuest or anyone else. Packages can build on each other; where two describe the same place, it is one sight and counts once."))
            }
        }
        .navigationTitle(tr("Sight packages"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosesFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                switch captures.readPackageFile(url) {
                case .success(let read): offer = read
                case .failure(let error): message = error.message
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .sheet(item: $offer) { offer in
            PackageOfferView(offer: offer) { self.offer = nil }
        }
        .alert(tr("Sight packages"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .alert(tr("Add from a link"), isPresented: $asksLink) {
            TextField(tr("Address"), text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(tr("Download")) { Task { await download() } }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("The web address of a sight package (https://…)."))
        }
    }

    private struct Group: Identifiable {
        let id: String
        let name: String
        let packages: [SightPackage]
    }

    /// The packages by region, in the regions' order; packages without one last.
    private var groups: [Group] {
        let library = captures.library
        var result: [Group] = []
        for region in library.regions {
            let members = library.packages.filter { $0.region?.id == region.id }
            if !members.isEmpty { result.append(Group(id: region.id, name: region.name(), packages: order(members))) }
        }
        let others = library.packages.filter { $0.region == nil }
        if !others.isEmpty { result.append(Group(id: "", name: tr("Other"), packages: order(others))) }
        return result
    }

    /// Packages that build on others first (the city before its parts), then by title.
    private func order(_ packages: [SightPackage]) -> [SightPackage] {
        packages.sorted { a, b in
            let ia = !(a.includes ?? []).isEmpty, ib = !(b.includes ?? []).isEmpty
            return ia != ib ? ia : a.title().localizedStandardCompare(b.title()) == .orderedAscending
        }
    }

    private func download() async {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else {
            message = tr("This is not a web address.")
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        switch await captures.downloadPackage(url) {
        case .success(let read): offer = read
        case .failure(let error): message = error.message
        }
    }
}

/// A package in a list: its title, what it holds, its version and publisher.
struct PackageRow: View {
    let package: SightPackage
    var warnings = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(package.title())
                    .font(.body.weight(.semibold))
                if warnings > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(trn("{0} note", "{0} notes", warnings))
                }
            }
            if !package.contentSummary.isEmpty {
                Text(package.contentSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text([tr("Version {0}", package.version), package.publisher].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// One installed package: about it, what it holds, what it builds on and is part of,
/// what it shares with other packages, notes from resolving it – and removing it.
struct SightPackageDetailView: View {
    let packageID: String
    @EnvironmentObject private var captures: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        if let package = captures.library.packages.first(where: { $0.id == packageID }) {
            content(package)
        } else {
            Text(tr("This package is not installed."))
                .foregroundStyle(.secondary)
        }
    }

    private func content(_ package: SightPackage) -> some View {
        let library = captures.library
        let issues = library.issues(of: package.id)
        let shared = (package.sights ?? []).filter { (library.packagesOfSight[library.canonical($0.id)]?.count ?? 0) > 1 }
        let partOf = library.packages.filter { ($0.includes ?? []).contains(package.id) }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(package.title())
                        .font(.title3.weight(.semibold))
                    if let summary = package.summary?(), !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                fact(tr("Version"), package.version)
                if let publisher = package.publisher { fact(tr("Publisher"), publisher) }
                if let region = package.region { fact(tr("Region"), region.name()) }
                if let homepage = package.homepage {
                    Link(destination: homepage) {
                        Label(homepage.host ?? homepage.absoluteString, systemImage: "safari")
                    }
                }
                if let license = package.license {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Licence"))
                        Text(license)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(package.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            } header: {
                Text(tr("About"))
            }

            Section {
                let sights = package.sights ?? []
                let remembrance = sights.filter { library.categories.isRemembrance($0.category) }.count
                if !sights.isEmpty {
                    fact(tr("Sights"), Formatters.number(sights.count - remembrance))
                }
                if remembrance > 0 { fact(tr("Places of remembrance"), Formatters.number(remembrance)) }
                if let achievements = package.achievements, !achievements.isEmpty {
                    fact(tr("Achievements"), Formatters.number(achievements.count))
                }
                if let transit = package.transit {
                    fact(tr("Stations"), Formatters.number(transit.stations.count))
                    fact(tr("Lines"), Formatters.number(transit.lines.count))
                }
                if let guide = package.remembrance {
                    fact(tr("Chapters of remembrance"), Formatters.number(guide.chapters.count))
                    if let tours = guide.tours, !tours.isEmpty { fact(tr("Walks"), Formatters.number(tours.count)) }
                }
                if let chronicles = package.chronicles, !chronicles.isEmpty {
                    fact(tr("History"), chronicles.map { $0.name() }.joined(separator: ", "))
                }
                if let categories = package.categories, !categories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Its own categories"))
                        ForEach(categories, id: \.id) { definition in
                            Label {
                                Text(tr("{0} (a kind of {1})", definition.title(), library.categories.core(of: definition.id).title))
                            } icon: {
                                Image(systemName: definition.id.symbol)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(tr("Contents"))
            }

            if !(package.includes ?? []).isEmpty || !partOf.isEmpty {
                Section {
                    ForEach(package.includes ?? [], id: \.self) { id in
                        let included = library.packages.first { $0.id == id }
                        Label {
                            Text(included?.title() ?? id)
                        } icon: {
                            Image(systemName: included == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(included == nil ? Color.orange : Color.green)
                        }
                    }
                    ForEach(partOf) { other in
                        Label(tr("Part of “{0}”", other.title()), systemImage: "shippingbox")
                    }
                } header: {
                    Text(tr("Builds on"))
                } footer: {
                    Text(tr("Its achievements count the places of the packages it builds on, too. A package it builds on that is missing can be added on its own."))
                }
            }

            if !shared.isEmpty {
                Section {
                    Text(trn("{0} of its sights is also in other packages: it is one sight, captured once.",
                             "{0} of its sights are also in other packages: each is one sight, captured once.", shared.count))
                        .font(.footnote)
                }
            }

            if !issues.isEmpty {
                Section {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message(names: name(of:)))
                            .font(.footnote)
                    }
                } header: {
                    Text(trn("{0} note", "{0} notes", issues.count))
                }
            }

            Section {
                ShareLink(item: captures.packageStore.url(of: package.id)) {
                    Label(tr("Share package file"), systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label(tr("Remove package"), systemImage: "trash")
                }
            } footer: {
                Text(tr("Removing a package takes its sights, achievements and places of remembrance off the map. What you discovered and captured is kept: add the package again and it is all back."))
            }
        }
        .navigationTitle(package.title())
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(tr("Remove “{0}”?", package.title()), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(tr("Remove"), role: .destructive) {
                dismiss()
                captures.removePackage(package.id)
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func name(of id: String) -> String {
        captures.catalog[captures.library.canonical(id)]?.name ?? captures.stations[id]?.name ?? id
    }
}

/// Packages read from a file or link: what they bring, before they are added; then
/// what adding them did.
struct PackageOfferView: View {
    let offer: PackageOffer
    let onClose: () -> Void
    @EnvironmentObject private var captures: CaptureModel
    @State private var results: [PackageInstallResult]?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let results {
                    Section {
                        ForEach(results) { result in
                            Label(result.message, systemImage: {
                                if case .keptNewer = result.outcome { return "info.circle.fill" }
                                return "checkmark.circle.fill"
                            }())
                        }
                    } footer: {
                        Text(tr("Its sights, achievements and places of remembrance are on the map and in the list now. Places you have been to already are discovered."))
                    }
                } else {
                    Section {
                        ForEach(offer.packages) { package in
                            VStack(alignment: .leading, spacing: 4) {
                                PackageRow(package: package)
                                if let summary = package.summary?(), !summary.isEmpty {
                                    Text(summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if let installed = captures.installedVersion(of: package.id) {
                                    Text(note(installed: installed, offered: package.version))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    } header: {
                        Text(tr("From {0}", offer.source))
                    } footer: {
                        Text(tr("Its sights, achievements and places of remembrance appear on the map and in the list. You can remove it in the menu under Sight packages."))
                    }
                    if let errorText {
                        Section {
                            Label(errorText, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(results != nil ? tr("Sight packages")
                             : trn("Add sight package?", "Add sight packages?", offer.packages.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if results != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tr("Done"), action: onClose)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("Cancel"), action: onClose)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tr("Add"), action: add)
                    }
                }
            }
        }
    }

    private func note(installed: String, offered: String) -> String {
        if installed == offered { return tr("Installed already") }
        if SightPackage.isVersion(offered, newerThan: installed) { return tr("Updates version {0}", installed) }
        return tr("Version {0} is installed and newer: it is kept", installed)
    }

    private func add() {
        do {
            results = try captures.installPackages(from: offer.data)
        } catch let error as SightPackageFile.FileError {
            errorText = error.message
        } catch {
            errorText = tr("The package could not be added: {0}", error.localizedDescription)
        }
    }
}
