import MapQuestCore
import SwiftUI
import UIKit

/// The capture animation: a golden medallion bursts into view over a dimmed
/// screen, rays turn behind it, sparks fly out. Three kinds: a sight discovered
/// (its entry unlocked – take a photo to capture it), a sight captured (the
/// photo in the medallion, with the achievements it completes), and lines of
/// stations completed. It ends by itself after a few seconds; a tap anywhere
/// ends it at once; buttons photograph the sight, open its entry, show it on the
/// map or open the list.
struct CaptureCelebrationView: View {
    let celebration: Celebration
    /// "Built 1788–1791 · Kingdom of Prussia" when a single sight was discovered or captured.
    var epoch: String?
    /// The capture's photo (in the medallion).
    var photo: UIImage?
    /// Takes a photo of a discovered sight (to capture it).
    var onPhotograph: ((Sight) -> Void)?
    let onFinish: () -> Void
    /// Opens the entry of a sight.
    var onRead: (Sight) -> Void = { _ in }
    /// Shows a sight on the map.
    var onShow: (Sight) -> Void = { _ in }
    /// Opens the list of sights or achievements.
    var onList: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var burst = false
    @State private var spin = false
    @State private var finished = false

    private static let baseDuration: Double = 4.5
    private static let sparks = 22

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.7 : 0)
                .ignoresSafeArea()

            // Rays behind the medallion.
            Rays(count: 14)
                .fill(RadialGradient(
                    colors: [Color.captureGold.opacity(0.55), Color.captureGold.opacity(0)],
                    center: .center, startRadius: 20, endRadius: 260
                ))
                .frame(width: 520, height: 520)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .scaleEffect(appeared ? 1 : 0.2)
                .opacity(appeared ? 1 : 0)
                .frame(width: 10, height: 10)  // does not widen the layout
                .allowsHitTesting(false)

            // Sparks flying out.
            ForEach(0..<Self.sparks, id: \.self) { index in
                let angle = Double(index) / Double(Self.sparks) * 2 * .pi + (index.isMultiple(of: 2) ? 0.12 : -0.08)
                let distance: Double = index.isMultiple(of: 3) ? 170 : 130
                Circle()
                    .fill(index.isMultiple(of: 2) ? Color.captureGold : Color.white)
                    .frame(width: index.isMultiple(of: 3) ? 9 : 6, height: index.isMultiple(of: 3) ? 9 : 6)
                    .offset(x: burst ? cos(angle) * distance : 0, y: burst ? sin(angle) * distance : 0)
                    .opacity(burst ? 0 : 1)
            }

            VStack(spacing: 14) {
                medallion
                    .scaleEffect(appeared ? 1 : 0.1)
                    .rotationEffect(.degrees(appeared ? 0 : -40))
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                VStack(spacing: 2) {
                    Text(names)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.captureGold)
                        .lineLimit(4)
                    // In English, the German original under the name.
                    if celebration.kind != .lines, celebration.sights.count == 1, let otherName = celebration.sights[0].otherName {
                        Text(otherName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                if let epoch {
                    Label(epoch, systemImage: "hourglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Text(countLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                if let badge {
                    Label(badge.text, systemImage: badge.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.85), in: Capsule())
                        .padding(.horizontal, 24)
                }
                if !celebration.achievements.isEmpty && celebration.kind != .lines {
                    achievementBanner
                        .scaleEffect(appeared ? 1 : 0.6)
                }
                buttons
                    .padding(.top, 6)
                Text(tr("Tap anywhere to continue"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 30)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityAction(.escape) { finish() }
        .task {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) { appeared = true }
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) { appeared = true }
                withAnimation(.easeOut(duration: 1.3).delay(0.15)) { burst = true }
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) { spin = true }
            }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            // Gone already (tapped away, or replaced): nothing more to finish.
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    /// Longer when achievements were unlocked, to read them.
    private var duration: Double { celebration.achievements.isEmpty ? Self.baseDuration : Self.baseDuration + 2 }

    /// The achievements these captures completed (three at most, then how many more).
    private var achievementBanner: some View {
        VStack(spacing: 6) {
            Text(trn("ACHIEVEMENT UNLOCKED", "ACHIEVEMENTS UNLOCKED", celebration.achievements.count))
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.captureGold)
            ForEach(celebration.achievements.prefix(3), id: \.id) { achievement in
                Label {
                    Text(achievement.title)
                } icon: {
                    AchievementSymbol(name: achievement.symbol, size: 14, color: .black)
                }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.captureGold, in: Capsule())
            }
            if celebration.achievements.count > 3 {
                Text(tr("and {0} more", celebration.achievements.count - 3))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch celebration.kind {
        case .discovered:
            return celebration.sights.count == 1 ? tr("Discovered!") : tr("{0} sights discovered!", celebration.sights.count)
        case .photographed:
            return tr("Captured!")
        case .lines:
            return celebration.achievements.contains { $0.rule.line != nil } ? tr("Line complete!") : tr("Achievement unlocked!")
        }
    }

    private var countLine: String {
        switch celebration.kind {
        case .discovered: return tr("{0} of {1} sights discovered", celebration.capturedCount, celebration.totalCount)
        case .photographed: return tr("{0} of {1} sights captured", celebration.capturedCount, celebration.totalCount)
        case .lines: return tr("{0} of {1} stations collected", celebration.capturedCount, celebration.totalCount)
        }
    }

    private var badge: (text: String, symbol: String)? {
        switch celebration.kind {
        case .discovered:
            return (celebration.sights.count == 1 ? tr("Entry unlocked · photograph it to capture it")
                        : tr("Entries unlocked · photograph them to capture them"),
                    "camera.fill")
        case .photographed:
            return (tr("Photo saved in its entry"), "photo.fill")
        case .lines:
            return nil
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch celebration.kind {
        case .discovered where celebration.sights.count == 1:
            let sight = celebration.sights[0]
            VStack(spacing: 10) {
                if let onPhotograph {
                    Button {
                        finished = true
                        onPhotograph(sight)
                    } label: {
                        Label(tr("Take a photo"), systemImage: "camera.fill")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                // Side by side; one above the other where they do not fit (longer German labels).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        readAndShowButtons(sight)
                    }
                    VStack(spacing: 10) {
                        readAndShowButtons(sight)
                    }
                }
            }
        case .discovered:
            Button {
                finished = true
                onList()
            } label: {
                Label(tr("See the sights"), systemImage: "list.bullet")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        case .photographed:
            EmptyView()
        case .lines:
            Button {
                finished = true
                onList()
            } label: {
                Label(tr("See the achievements"), systemImage: "rosette")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    /// "Read entry" and "Show on map" for a single discovered sight.
    @ViewBuilder
    private func readAndShowButtons(_ sight: Sight) -> some View {
        Button {
            finished = true
            onRead(sight)
        } label: {
            Label(tr("Read entry"), systemImage: "book")
        }
        .buttonStyle(.bordered)
        .tint(.white)
        Button {
            finished = true
            onShow(sight)
        } label: {
            Label(tr("Show on map"), systemImage: "map")
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private var medallion: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.9, blue: 0.45), .captureGold, .orange],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 128, height: 128)
                .shadow(color: Color.captureGold.opacity(0.8), radius: 24)
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 4)
                .frame(width: 112, height: 112)
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 104)
                    .clipShape(Circle())
            } else {
                Image(systemName: medallionSymbol)
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
    }

    private var medallionSymbol: String {
        switch celebration.kind {
        case .lines: return "tram.fill"
        case .photographed: return "camera.fill"
        case .discovered: return celebration.sights.count == 1 ? celebration.sights[0].category.symbol : "sparkles"
        }
    }

    private var names: String {
        let names = celebration.kind == .lines ? celebration.achievements.map(\.title) : celebration.sights.map(\.name)
        guard names.count > 4 else { return names.joined(separator: " · ") }
        return names.prefix(4).joined(separator: " · ") + " " + tr("and {0} more", names.count - 4)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

/// Wedge-shaped rays around the centre.
private struct Rays: Shape {
    let count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let half = Double.pi / Double(count) / 2.2
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle - half) * radius, y: center.y + sin(angle - half) * radius))
            path.addLine(to: CGPoint(x: center.x + cos(angle + half) * radius, y: center.y + sin(angle + half) * radius))
            path.closeSubpath()
        }
        return path
    }
}
