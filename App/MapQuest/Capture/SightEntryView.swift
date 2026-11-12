import CoreLocation
import CryptoKit
import MapQuestCore
import SwiftUI
import UIKit

/// A sight's entry: locked until the sight is captured, then – where Apple has
/// photorealistic 3D buildings – an interactive photorealistic 3D view of it,
/// otherwise its photo; a description (Wikipedia introduction), its historical
/// facts (built, opened, style, architects, client, the era and ruler at the
/// time) and the history of the place, with the credits the licences ask for.
struct SightEntryView: View {
    let sight: Sight
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss

    private var record: CaptureRecord? { captures.log.records[sight.id] }
    private var info: SightInfo? { captures.infos[sight.id] }
    private var history: SightHistory? { captures.histories[sight.id] }
    @State private var showsFullHistory = false
    @State private var showsCamera = false
    /// The source the camera sheet was opened with (kept while it is open).
    @State private var pickerSource: UIImagePickerController.SourceType = .camera
    /// The capture animation, over the entry, after a first photo.
    @State private var celebration: Celebration?
    @State private var saveError: String?
    /// Your photo of the sight (loaded once per photo).
    @State private var photo: UIImage?
    /// Photorealistic 3D at the top (the photo then follows the text).
    private var shows3D: Bool { captures.hasPhotorealistic3D(sight) }
    private var capture: PhotoCapture? { captures.log.photos[sight.id] }
    /// Places of remembrance are not part of the game: always open, quiet colours, nothing to capture.
    private var isRemembrance: Bool { sight.isPlaceOfRemembrance }
    private var accent: Color { isRemembrance ? .remembrance : .orange }
    /// The camera (or the photo library for testing), if it can be used here and now.
    private var cameraSource: UIImagePickerController.SourceType? {
        guard captures.canPhotograph(sight, from: tracker.lastLocation) else { return nil }
        return CameraPicker.source(allowingLibrary: captures.photosAnywhere)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isRemembrance {
                    remembrance
                } else if let record {
                    unlocked(record)
                } else {
                    locked
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(record == nil && !isRemembrance ? "Undiscovered" : sight.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            captures.markRead(sight)
            // From the discovery animation's "Take a photo".
            if captures.cameraRequest == sight.id {
                captures.cameraRequest = nil
                openCamera()
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker(source: pickerSource) { image in save(image) }
                .ignoresSafeArea()
        }
        .overlay {
            if let celebration {
                CaptureCelebrationView(
                    celebration: celebration,
                    epoch: history?.epoch,
                    photo: photo,
                    onFinish: { self.celebration = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: celebration)
        .task(id: capture?.takenAt) { photo = captures.photo(for: sight) }
        .alert("The photo could not be saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Opens the camera if the sight can be photographed from here.
    private func openCamera() {
        guard let source = cameraSource else { return }
        pickerSource = source
        showsCamera = true
    }

    /// Saves the photo: the sight is captured (the animation plays for a first capture).
    private func save(_ image: UIImage) {
        do {
            if let shown = try captures.saveCapture(image, of: sight, at: tracker.lastLocation) {
                celebration = shown
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The photo capture: your photo once captured, else how to capture it.
    @ViewBuilder
    private var captureCard: some View {
        if let capture {
            VStack(alignment: .leading, spacing: 10) {
                Label("Captured \(capture.capturedAt.formatted(date: .long, time: .omitted))", systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.orange)
                // In an overlay: the photo's own size never widens the layout.
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 230)
                    .overlay {
                        if let photo {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ProgressView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Your photo of \(sight.name)")
                HStack {
                    if let photo {
                        ShareLink(item: Image(uiImage: photo), preview: SharePreview(sight.name, image: Image(uiImage: photo))) {
                            Label("Share or save", systemImage: "square.and.arrow.up")
                        }
                    }
                    Spacer()
                    if cameraSource != nil {
                        Button {
                            openCamera()
                        } label: {
                            Label("New photo", systemImage: "camera")
                        }
                    }
                }
                .font(.subheadline)
                .tint(.orange)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Capture it", systemImage: "camera.fill")
                    .font(.headline)
                    .foregroundStyle(Color.orange)
                Text(captureHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openCamera()
                } label: {
                    Label("Take a photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(cameraSource == nil)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var captureHint: String {
        if cameraSource != nil {
            return "Photograph \(sight.name) and keep the photo: it captures the sight and counts towards its achievements."
        }
        if captures.canPhotograph(sight, from: tracker.lastLocation) {
            return "This device has no camera."
        }
        if let meters = captures.distance(to: sight, from: tracker.lastLocation) {
            let away = meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m" : String(format: "%.1f km", meters / 1_000)
            return "Go back there to photograph it (\(away) away): within about \(Int(sight.radius + CaptureModel.photoReach)) m of it the camera opens."
        }
        return "Go there to photograph it: the camera opens once you are near it."
    }

    // MARK: Parts

    @ViewBuilder
    private var header: some View {
        if record == nil && !isRemembrance {
            banner(locked: true) {
                LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                    .overlay {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
            }
        } else if shows3D {
            VStack(alignment: .leading, spacing: 10) {
                SightFlyoverView(sight: sight)
                    .frame(height: 300)
                    .overlay(alignment: .bottomTrailing) {
                        Label("Drag, pinch, turn and tilt", systemImage: "view.3d")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                title
                    .padding(.horizontal)
            }
        } else {
            banner(locked: false) {
                if let photo = info?.image {
                    SightPhotoView(url: photo.url)
                } else {
                    LinearGradient(colors: [accent.opacity(0.6), accent.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                        .overlay {
                            Image(systemName: sight.category.symbol)
                                .font(.system(size: 54, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                }
            }
        }
    }

    /// Name and category under the 3D view.
    private var title: some View {
        HStack(alignment: .center, spacing: 10) {
            SightBadge(category: sight.category, captured: capture != nil, discovered: true, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(sight.category.title.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isRemembrance ? Color.secondary : Color.orange)
                Text(sight.name)
                    .font(.title2.bold())
                    .lineLimit(2)
            }
        }
    }

    /// A picture with name and category on it (photo, or the locked placeholder).
    private func banner<Background: View>(locked: Bool, @ViewBuilder background: () -> Background) -> some View {
        ZStack(alignment: .bottomLeading) {
            background()
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .frame(height: 240)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 10) {
                SightBadge(category: sight.category, captured: capture != nil, discovered: !locked, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(locked ? "Undiscovered \(sight.category.title.lowercased())" : sight.category.title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(locked || isRemembrance ? Color.white.opacity(0.85) : Color.orange)
                    Text(locked ? "???" : sight.name)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }
            .padding(14)
        }
    }

    private func unlocked(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Discovered \(record.capturedAt.formatted(date: .long, time: .omitted))", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            captureCard
            if let info {
                ForEach(Array(info.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.body)
                }
            } else {
                Text("No entry for this sight yet.")
                    .foregroundStyle(.secondary)
            }
            if let history {
                SightHistoryFacts(history: history)
                    .padding(.top, 4)
                historyText(history)
            }
            SightAchievements(sight: sight)
                .padding(.top, 4)
            if shows3D, let photo = info?.image {
                SightPhotoView(url: photo.url)
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 4)
            }
            actions
            if let info {
                credits(info)
            }
        }
        .padding(.horizontal)
    }

    /// A place of remembrance: why it is not part of the game, its entry and history.
    private var remembrance: some View {
        VStack(alignment: .leading, spacing: 14) {
            RemembranceHeader(visitedAt: record?.capturedAt)
            if let info {
                ForEach(Array(info.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.body)
                }
            } else {
                Text("No entry for this place yet.")
                    .foregroundStyle(.secondary)
            }
            if let history {
                SightHistoryFacts(history: history, tint: .remembrance)
                    .padding(.top, 4)
                historyText(history)
            }
            if shows3D, let photo = info?.image {
                SightPhotoView(url: photo.url)
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 4)
            }
            actions
            if let info {
                credits(info)
            }
        }
        .padding(.horizontal)
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This entry is locked.")
                .font(.headline)
            Text("Go there to discover it: once the circles of the radius view cover the sight, it appears on your map and its entry opens here – with when it was built and by whom, who ruled Berlin then, and the history of the place. Then photograph it there to capture it.")
                .foregroundStyle(.secondary)
            if let location = tracker.lastLocation {
                let meters = location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
                Label(meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m away" : String(format: "%.1f km away", meters / 1_000),
                      systemImage: "location.fill")
                    .font(.subheadline)
            }
            SightAchievements(sight: sight)
            actions
        }
        .padding(.horizontal)
    }

    /// The history of the place: the first two paragraphs, the rest on request.
    @ViewBuilder
    private func historyText(_ history: SightHistory) -> some View {
        let paragraphs = history.historyParagraphs
        if !paragraphs.isEmpty {
            Text("History")
                .font(.headline)
                .padding(.top, 4)
            let shown = showsFullHistory ? paragraphs : Array(paragraphs.prefix(2))
            ForEach(Array(shown.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.body)
            }
            if paragraphs.count > shown.count {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsFullHistory = true }
                } label: {
                    Label("Read more", systemImage: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(accent)
            }
        }
    }

    private var actions: some View {
        Button {
            dismiss()
            captures.show(sight)
        } label: {
            Label("Show on map", systemImage: "map")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .padding(.top, 4)
    }

    private static let textLicense = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!

    private func credits(_ info: SightInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: info.url) {
                Label("Read the full article on Wikipedia", systemImage: "book")
            }
            .font(.subheadline)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Text: Wikipedia, “\(info.title)” (\(info.language == "de" ? "German" : "English")), CC BY-SA 4.0")
                Link("Licence: creativecommons.org/licenses/by-sa/4.0", destination: Self.textLicense)
                if let history {
                    Text("Facts: checked by hand against Wikidata (CC0) and Wikipedia; rulers and eras: MapQuest")
                        .padding(.top, 4)
                    if let item = history.wikidata {
                        Link("Wikidata item", destination: item)
                    }
                }
                if let photo = info.image {
                    Text("Photo: \(photo.artist), \(photo.license)")
                        .padding(.top, 4)
                    Link("Photo on Wikimedia Commons", destination: photo.page)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

/// A sight's historical facts in a card: built, opened, style, architects, client,
/// who ruled and the era, and where it lay while the city was divided.
struct SightHistoryFacts: View {
    let history: SightHistory
    /// Orange; stone grey for places of remembrance.
    var tint: Color = .orange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("In history", systemImage: "hourglass")
                .font(.headline)
                .foregroundStyle(tint)
            if let built = history.built {
                fact("Built", built, symbol: "hammer.fill")
            }
            if let opened = history.opened {
                fact("Opened", opened, symbol: "door.left.hand.open")
            }
            if !history.styles.isEmpty {
                fact(history.styles.count == 1 ? "Style" : "Styles", history.styles.joined(separator: ", "), symbol: "building.columns.fill")
            }
            if !history.architects.isEmpty {
                fact(history.architects.count == 1 ? "Architect" : "Architects and artists", history.architects.joined(separator: ", "), symbol: "pencil.and.ruler.fill")
            }
            if !history.commissionedBy.isEmpty {
                fact("Commissioned by", history.commissionedBy.joined(separator: ", "), symbol: "signature")
            }
            if let context = history.context {
                if let ruler = context.ruler {
                    fact(history.year.map { "Ruling in \(String($0))" } ?? "Ruling at the time",
                         "\(ruler.name), \(ruler.title) (\(ruler.reign))", symbol: Self.isMonarchy(context.era) ? "crown.fill" : "person.fill")
                }
                fact("Era", "\(context.era.name) (\(context.era.years))", detail: context.era.summary, symbol: "clock.arrow.circlepath")
            }
            if let sector = history.sectorDuringDivision {
                fact("While Berlin was divided", sector.title, symbol: "square.split.2x1.fill")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.3), lineWidth: 1))
    }

    static func isMonarchy(_ era: HistoricalEra) -> Bool {
        ["margraviate", "electorate", "prussia", "empire"].contains(era.id)
    }

    private func fact(_ title: String, _ value: String, detail: String? = nil, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A sight photo, loaded once and kept on disk. It fills the space it is given
/// and is cropped to it: the photo's own size (e.g. a wide panorama) never
/// widens the layout – the image lies in an overlay of a flexible rectangle.
struct SightPhotoView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .task(id: url) {
                let loaded = await SightPhotoLoader.shared.image(for: url)
                withAnimation(.easeIn(duration: 0.25)) { image = loaded }
            }
    }
}

/// Loads sight photos (Wikimedia) and keeps them in Caches/SightPhotos.
final class SightPhotoLoader: @unchecked Sendable {
    static let shared = SightPhotoLoader()
    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SightPhotos")
    private let session: URLSession = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "MapQuest/\(version) (iOS)"]
        return URLSession(configuration: configuration)
    }()

    func image(for url: URL) async -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name + ".img")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        memory.setObject(image, forKey: url as NSURL)
        return image
    }
}
