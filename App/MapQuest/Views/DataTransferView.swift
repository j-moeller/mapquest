import MapQuestCore
import SwiftUI
import UniformTypeIdentifiers

/// The settings an export carries along (restored when it replaces a data source).
struct ExportedSettings: Codable {
    var debug: DebugSettings
    var mapIcons: MapIconFilter
    var savesToPhotos: Bool
}

/// Menu › Export and import: everything of a data source as one ZIP file – to keep
/// a backup, or to move to another iPhone – and back.
struct DataTransferView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var captures: CaptureModel
    @State private var export: (url: URL, manifest: DataArchive.Manifest, bytes: Int64)?
    @State private var choosesFile = false
    @State private var pending: DataArchive.Reader?
    @State private var confirmReplace = false
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                if let export {
                    ShareLink(item: export.url) {
                        Label(tr("Save or share the export ({0})", Formatters.bytes(Int(export.bytes))), systemImage: "square.and.arrow.up")
                    }
                    Text(summary(export.manifest))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await makeExport() }
                    } label: {
                        Label(tr("Create export of “{0}”", model.profile.name), systemImage: "archivebox")
                    }
                    .disabled(model.isBusy)
                }
            } header: {
                Text(tr("Export"))
            } footer: {
                Text(tr("One ZIP file with everything that makes up this data source: every recorded position, the positions the map is computed from, sights and stations, all photos and the settings. Save it in Files or send it to yourself; the discovered area is recomputed from it."))
            }

            Section {
                if let reader = pending {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("“{0}”, exported {1}", reader.manifest.source.name, Formatters.dateTime(reader.manifest.exportedAt)))
                            .font(.subheadline.weight(.semibold))
                        Text(summary(reader.manifest))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if model.canReplaceSelectedData {
                        Button(tr("Replace the data of “{0}”", model.profile.name), role: .destructive) {
                            confirmReplace = true
                        }
                    }
                    Button(tr("Add as a new data source")) {
                        Task { await runImport(reader, into: .newDataSource) }
                    }
                    Button(tr("Cancel"), role: .cancel) {
                        pending = nil
                    }
                } else {
                    Button {
                        choosesFile = true
                    } label: {
                        Label(tr("Import an export…"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.isBusy)
                }
            } header: {
                Text(tr("Import"))
            } footer: {
                Text(tr("Replacing restores this data source as it was exported, settings included; what it holds now is deleted. A new data source shows the export next to your own discoveries, without recording into it."))
            }

            if isWorking || model.progress != nil {
                Section {
                    if let progress = model.progress {
                        ProgressView(value: progress) {
                            Text(model.lastOutcome).font(.footnote)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle(tr("Export and import"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosesFile, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): openArchive(url)
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .confirmationDialog(
            tr("Replace everything in “{0}” with the export?", model.profile.name),
            isPresented: $confirmReplace, titleVisibility: .visible
        ) {
            Button(tr("Replace"), role: .destructive) {
                if let reader = pending { Task { await runImport(reader, into: .replaceSelected) } }
            }
        } message: {
            Text(tr("Its positions, discoveries and photos are deleted and replaced. Export it first if you want to keep them."))
        }
        .alert(tr("Export and import"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    /// "12,345 positions on 12 days · 40 sights discovered, 12 captured · 30 photos".
    private func summary(_ manifest: DataArchive.Manifest) -> String {
        [
            tr("{0} positions on {1} days", Formatters.number(manifest.trackPoints), Formatters.number(manifest.trackDays.count)),
            tr("{0} sights discovered, {1} captured", Formatters.number(manifest.sightsDiscovered), Formatters.number(manifest.sightsCaptured)),
            trn("{0} station", "{0} stations", manifest.stationsCollected),
            trn("{0} photo", "{0} photos", manifest.photos.count),
        ].joined(separator: " · ")
    }

    private func makeExport() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let (url, manifest) = try await model.exportData(captures: captures)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            export = (url, manifest, bytes)
        } catch {
            errorText = tr("The export could not be created: {0}", error.localizedDescription)
        }
    }

    /// Copies the chosen file (it may be outside the app's reach later) and reads what it holds.
    private func openArchive(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Import", isDirectory: true) // not localized: a folder
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("import.zip")
            try FileManager.default.copyItem(at: url, to: copy)
            pending = try DataArchive.Reader(url: copy)
        } catch DataArchive.ArchiveError.notAMapQuestArchive {
            errorText = tr("This file is not a MapQuest export.")
        } catch DataArchive.ArchiveError.newerVersion {
            errorText = tr("This export is from a newer version of MapQuest. Update the app to import it.")
        } catch {
            errorText = tr("The file could not be read: {0}", error.localizedDescription)
        }
    }

    private func runImport(_ reader: DataArchive.Reader, into target: AppModel.ImportTarget) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.importData(reader, into: target, captures: captures)
            pending = nil
        } catch {
            errorText = tr("The import failed: {0}", error.localizedDescription)
        }
    }
}
