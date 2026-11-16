import MapQuestCore
import SwiftUI

/// What a recording brought, over the map when it ends: the time, distance walked,
/// area uncovered, sights found and captured, and up to three of the photos taken.
/// A tap anywhere closes it.
struct RecordingSummaryView: View {
    let summary: RecordingSummary
    let onClose: () -> Void
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.6 : 0)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.captureGold)
                    Text(tr("Recording ended"))
                        .font(.title2.bold())
                    Text(timeSpan)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        tile(Formatters.distance(summary.walkedMeters), tr("Walked"), symbol: "figure.walk", tint: .green)
                        tile(Formatters.area(summary.uncoveredSquareMeters), tr("Area uncovered"), symbol: "square.dashed.inset.filled", tint: .orange)
                    }
                    GridRow {
                        tile(Formatters.number(summary.sightsFound), tr("Sights found"), symbol: "binoculars.fill", tint: .orange)
                        tile(Formatters.number(summary.sightsCaptured), tr("Sights captured"), symbol: "camera.fill", tint: .captureGold)
                    }
                }

                if !summary.photos.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(summary.photos) { photo in
                            TakenPhotoImage(photo: photo, maxPixels: 400)
                                .frame(width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .accessibilityLabel(trn("{0} photo", "{0} photos", summary.photos.count))
                }

                Text(tr("Tap anywhere to close"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(24)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tr("Closes the summary"))
    }

    /// "14:05–15:17 · 1 h 12 min".
    private var timeSpan: String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened).locale(Formatters.locale)
        return summary.start.formatted(style) + "–" + summary.end.formatted(style) + " · " + Formatters.duration(summary.duration)
    }

    private func tile(_ value: String, _ label: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}
