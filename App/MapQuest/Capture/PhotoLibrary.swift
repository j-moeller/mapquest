import CoreLocation
import Photos
import UIKit

/// Saves photos of sights to the Photos app (add-only access: MapQuest never reads
/// the library), with where and when they were taken.
enum PhotoLibrary {
    /// Whether the user declined adding photos (the menu says how to allow it).
    static var isDenied: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .denied || status == .restricted
    }

    static func save(_ image: UIImage, location: CLLocation?, date: Date) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                request.creationDate = date
                request.location = location
            }, completionHandler: { _, _ in })
        }
    }
}

extension PhotoLibrary {
    /// Asks for add-only access now (when saving is switched on); whether it is allowed.
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
}
