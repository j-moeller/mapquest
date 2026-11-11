import CoreLocation
import CryptoKit
import MapQuestCore
import SwiftUI
import UIKit

/// A sight's entry: locked until the sight is captured, then its photo, a
/// description and its history (Wikipedia introduction) with the credits the
/// licences ask for.
struct SightEntryView: View {
    let sight: Sight
    @EnvironmentObject private var captures: CaptureModel
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss

    private var record: CaptureRecord? { captures.log.records[sight.id] }
    private var info: SightInfo? { captures.infos[sight.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let record {
                    unlocked(record)
                } else {
                    locked
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(record == nil ? "Undiscovered" : sight.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { captures.markRead(sight) }
    }

    // MARK: Parts

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if record != nil, let photo = info?.image {
                    SightPhotoView(url: photo.url)
                } else {
                    LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                        .overlay {
                            Image(systemName: record == nil ? "lock.fill" : sight.category.symbol)
                                .font(.system(size: 54, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                }
            }
            .frame(height: 230)
            .frame(maxWidth: .infinity)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .frame(height: 230)
            HStack(alignment: .bottom, spacing: 10) {
                SightBadge(category: sight.category, captured: record != nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record == nil ? "Undiscovered \(sight.category.title.lowercased())" : sight.category.title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(record == nil ? Color.white.opacity(0.8) : Color.orange)
                    Text(record == nil ? "???" : sight.name)
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
            if let info {
                let paragraphs = info.paragraphs
                if let first = paragraphs.first {
                    Text(first)
                        .font(.body)
                }
                if paragraphs.count > 1 {
                    Text("History and more")
                        .font(.headline)
                        .padding(.top, 4)
                    ForEach(Array(paragraphs.dropFirst().enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                    }
                }
            } else {
                Text("No entry for this sight yet.")
                    .foregroundStyle(.secondary)
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
            Text("Go there to unlock its story: once the circles of the radius view cover the sight, it is captured, appears on your map and its entry opens here.")
                .foregroundStyle(.secondary)
            if let location = tracker.lastLocation {
                let meters = location.distance(from: CLLocation(latitude: sight.latitude, longitude: sight.longitude))
                Label(meters < 1_000 ? "\(Int((meters / 10).rounded() * 10)) m away" : String(format: "%.1f km away", meters / 1_000),
                      systemImage: "location.fill")
                    .font(.subheadline)
            }
            actions
        }
        .padding(.horizontal)
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
        .tint(.orange)
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

/// A sight photo, loaded once and kept on disk.
struct SightPhotoView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.25)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                ProgressView()
            }
        }
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
