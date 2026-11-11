import MapQuestCore
import SwiftUI
import UIKit

/// The capture animation: a golden medallion with the sight's icon bursts into
/// view over a dimmed screen, rays turn behind it, sparks fly out; the sight's
/// entry is unlocked. It ends by itself after a few seconds; a tap anywhere ends
/// it at once; buttons open the entry or show the sight on the map.
struct CaptureCelebrationView: View {
    let celebration: Celebration
    /// "Built 1788–1791 · Kingdom of Prussia" when a single sight was captured.
    var epoch: String?
    let onFinish: () -> Void
    /// Opens the entry of a sight.
    let onRead: (Sight) -> Void
    /// Shows a sight on the map.
    let onShow: (Sight) -> Void
    /// Opens the list of sights (several captured at once).
    let onList: () -> Void

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
                Text(celebration.sights.count == 1 ? "Captured!" : "\(celebration.sights.count) sights captured!")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text(names)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.captureGold)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 32)
                if let epoch {
                    Label(epoch, systemImage: "hourglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Text("\(celebration.capturedCount) of \(celebration.totalCount) sights")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                Label(celebration.sights.count == 1 ? "New entry unlocked" : "New entries unlocked", systemImage: "book.closed.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.85), in: Capsule())
                if !celebration.achievements.isEmpty {
                    achievementBanner
                        .scaleEffect(appeared ? 1 : 0.6)
                }
                buttons
                    .padding(.top, 6)
                Text("Tap anywhere to continue")
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
            Text(celebration.achievements.count == 1 ? "ACHIEVEMENT UNLOCKED" : "ACHIEVEMENTS UNLOCKED")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.captureGold)
            ForEach(celebration.achievements.prefix(3), id: \.id) { achievement in
                Label(achievement.title, systemImage: AchievementMedal.symbol(achievement.symbol))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.captureGold, in: Capsule())
            }
            if celebration.achievements.count > 3 {
                Text("and \(celebration.achievements.count - 3) more")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var buttons: some View {
        if celebration.sights.count == 1 {
            let sight = celebration.sights[0]
            HStack(spacing: 12) {
                Button {
                    finished = true
                    onRead(sight)
                } label: {
                    Label("Read entry", systemImage: "book")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Button {
                    finished = true
                    onShow(sight)
                } label: {
                    Label("Show on map", systemImage: "map")
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        } else {
            Button {
                finished = true
                onList()
            } label: {
                Label("See the sights", systemImage: "list.bullet")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
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
            Image(systemName: celebration.sights.count == 1 ? celebration.sights[0].category.symbol : "trophy.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }

    private var names: String {
        let names = celebration.sights.map(\.name)
        guard names.count > 4 else { return names.joined(separator: " · ") }
        return names.prefix(4).joined(separator: " · ") + " and \(names.count - 4) more"
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
