import SwiftUI
import UIKit

/// The system camera (or, for testing without a camera, the photo library). Its
/// own "Use Photo" step confirms the picture; `onImage` then saves it.
struct CameraPicker: UIViewControllerRepresentable {
    let source: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The camera where there is one; the photo library only when allowed (debug).
    static func source(allowingLibrary: Bool) -> UIImagePickerController.SourceType? {
        if UIImagePickerController.isSourceTypeAvailable(.camera) { return .camera }
        return allowingLibrary ? .photoLibrary : nil
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
