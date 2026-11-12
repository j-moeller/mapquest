import MapQuestCore
import SwiftUI

/// A quiet note that a place of remembrance was visited. Places of remembrance
/// are not part of the game: no animation, no sound or vibration, no counts –
/// the place's name, a sentence about it, its entry, and close.
struct RemembranceNoticeView: View {
    let notice: RemembranceNotice
    /// The first sentences of a place's entry.
    let intro: (Sight) -> String?
    let onRead: (Sight) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("PLACE OF REMEMBRANCE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if notice.sights.count == 1, let sight = notice.sights.first {
                    Text(sight.name)
                        .font(.title3.weight(.semibold))
                    if let intro = intro(sight) {
                        Text(intro)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                } else {
                    Text("You have been at \(notice.sights.count) places of remembrance")
                        .font(.title3.weight(.semibold))
                    Text(notice.sights.map(\.name).joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
                Text("Places of remembrance are not part of the game: there is nothing to capture and nothing to collect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if notice.sights.count == 1, let sight = notice.sights.first {
                        Button("Read about this place") { onRead(sight) }
                    }
                    Spacer()
                    Button("Close") { onClose() }
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The opening of a place of remembrance's entry: why it is not part of the game,
/// and – once you were there – when.
struct RemembranceHeader: View {
    let visitedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A place of remembrance. It is not part of the game – there is nothing to capture and no achievement – and its entry is open to everyone. Please visit it with respect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let visitedAt {
                Label("You were here on \(visitedAt.formatted(date: .long, time: .omitted))", systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.remembrance.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
