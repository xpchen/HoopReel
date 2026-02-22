import SwiftUI
import UIKit

// MARK: - ShareSheet

/// Wraps UIActivityViewController for use in SwiftUI.
/// Handles iPad popover anchor automatically.
struct ShareSheet: UIViewControllerRepresentable {

    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems:        activityItems,
            applicationActivities: applicationActivities
        )
        // iPad requires a source view for the popover anchor.
        vc.popoverPresentationController?.sourceView = UIView()
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {}
}
