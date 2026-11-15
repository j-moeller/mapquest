import MapQuestCore
import SwiftUI
import UIKit

/// A photo you took, made small and cropped to the space it is given (loaded off
/// the main thread; a grey square until then).
struct TakenPhotoImage: View {
    let photo: TakenPhoto
    var maxPixels = 400
    @EnvironmentObject private var captures: CaptureModel
    @State private var image: UIImage?

    var body: some View {
        // In an overlay: the photo's own size never widens the layout.
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: photo.fileName) {
                image = await captures.thumbnail(of: photo, maxPixels: maxPixels)
            }
    }
}

/// Menu › Photos: every photo you have taken of sights, newest first.
struct PhotoGalleryView: View {
    @EnvironmentObject private var captures: CaptureModel
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        let photos = captures.allPhotos
        Group {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label(tr("No photos yet"), systemImage: "photo.on.rectangle")
                } description: {
                    Text(tr("Photograph a sight you have discovered to capture it. Every photo you take of a sight is kept here."))
                }
            } else {
                ScrollView {
                    Text(summary(photos))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(photos) { photo in
                            NavigationLink {
                                TakenPhotoDetail(photo: photo)
                            } label: {
                                TakenPhotoImage(photo: photo)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(label(of: photo))
                        }
                    }
                }
            }
        }
        .navigationTitle(tr("Photos"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "12 photos · 7 sights".
    private func summary(_ photos: [TakenPhoto]) -> String {
        let sights = Set(photos.map(\.sightID)).count
        return [trn("{0} photo", "{0} photos", photos.count), trn("{0} sight", "{0} sights", sights)].joined(separator: " · ")
    }

    private func label(of photo: TakenPhoto) -> String {
        let name = captures.catalog[photo.sightID]?.name ?? photo.sightID
        return tr("Your photo of {0}", name) + ", " + Formatters.dateTime(photo.takenAt)
    }
}

/// One photo: large, with its sight and when it was taken; share or save it, open
/// the sight's entry, or delete it (the sight stays captured).
struct TakenPhotoDetail: View {
    let photo: TakenPhoto
    /// Off where the detail was opened from the entry itself.
    var linksToEntry = true
    @EnvironmentObject private var captures: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var confirmDelete = false

    private var sight: Sight? { captures.catalog[photo.sightID] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .overlay { ProgressView() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(tr("Your photo of {0}", sight?.name ?? photo.sightID))

                VStack(alignment: .leading, spacing: 4) {
                    if let sight {
                        Text(sight.name)
                            .font(.title3.weight(.semibold))
                    }
                    Label(tr("Taken {0}", Formatters.dateTime(photo.takenAt)), systemImage: "camera")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let sight, linksToEntry {
                    NavigationLink {
                        SightEntryView(sight: sight)
                    } label: {
                        Label(tr("Open entry"), systemImage: "book")
                    }
                }

                HStack {
                    if let url = captures.url(of: photo) {
                        ShareLink(item: url, preview: SharePreview(sight?.name ?? "", image: Image(uiImage: image ?? UIImage()))) {
                            Label(tr("Share or save"), systemImage: "square.and.arrow.up")
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(tr("Delete photo"), systemImage: "trash")
                    }
                }
                .font(.subheadline)
            }
            .padding()
        }
        .tint(.orange)
        .navigationTitle(tr("Photo"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photo.fileName) {
            image = await captures.thumbnail(of: photo, maxPixels: 2048)
        }
        .confirmationDialog(tr("Delete this photo?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(tr("Delete"), role: .destructive) {
                captures.deletePhoto(photo)
                dismiss()
            }
        } message: {
            Text(tr("It is deleted from MapQuest only (not from the Photos app). The sight stays captured."))
        }
    }
}

/// A sight's photos in its entry, newest first: the latest large, all of them in a
/// row below once there are several. Each opens the photo.
struct SightPhotoStrip: View {
    let photos: [TakenPhoto]
    let sightName: String

    var body: some View {
        if let latest = photos.first {
            VStack(alignment: .leading, spacing: 6) {
                NavigationLink {
                    TakenPhotoDetail(photo: latest, linksToEntry: false)
                } label: {
                    TakenPhotoImage(photo: latest, maxPixels: 1200)
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Your photo of {0}", sightName))
                if photos.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(photos) { photo in
                                NavigationLink {
                                    TakenPhotoDetail(photo: photo, linksToEntry: false)
                                } label: {
                                    TakenPhotoImage(photo: photo, maxPixels: 240)
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tr("Your photo of {0}", sightName) + ", " + Formatters.dateTime(photo.takenAt))
                            }
                        }
                    }
                }
            }
        }
    }
}
