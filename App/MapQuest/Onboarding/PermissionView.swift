import MapQuestCore
import SwiftUI
import UIKit

/// First-launch screen: explains what MapQuest does with the location and asks
/// for permission.
struct PermissionView: View {
    @EnvironmentObject private var tracker: LocationTracker
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            VStack(spacing: 12) {
                Text(tr("Lift the fog of war"))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(tr("MapQuest only shows the parts of Berlin you have actually been to. Everything else stays in the dark until you go there."))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                PrivacyRow(symbol: "location.fill", text: tr("Your position is used to reveal the map around you – also in the background, if you allow it."))
                PrivacyRow(symbol: "internaldrive", text: tr("Positions are stored only on this iPhone, and only when they reveal something new."))
                PrivacyRow(symbol: "hand.raised.fill", text: tr("You can pause tracking or delete all data at any time."))
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
            Button {
                tracker.requestWhenInUseAuthorization()
            } label: {
                Text(tr("Allow location access"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Button(tr("Not now"), action: onSkip)
                .font(.subheadline)
        }
        .padding(24)
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A banner that explains missing or limited permission and offers a fix.
struct PermissionBanner: View {
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        if tracker.isDenied {
            banner(
                text: tr("Location access is off, so nothing can be discovered."),
                action: tr("Open Settings"),
                perform: openSettings
            )
        } else if tracker.needsPermissionPrompt {
            banner(
                text: tr("Allow location access to start discovering."),
                action: tr("Allow"),
                perform: tracker.requestWhenInUseAuthorization
            )
        } else if tracker.authorizationStatus == .authorizedWhenInUse {
            banner(
                text: tr("Allow “Always” to keep discovering after MapQuest was closed."),
                action: tr("Upgrade"),
                perform: tracker.requestAlwaysAuthorization
            )
        } else if tracker.accuracyAuthorization == .reducedAccuracy {
            banner(
                text: tr("Precise location is off – discoveries need it."),
                action: tr("Open Settings"),
                perform: openSettings
            )
        }
    }

    private func banner(text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "location.slash")
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
                .font(.footnote.bold())
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
