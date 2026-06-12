import SwiftUI

#if canImport(UIKit)
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ viewController: UIActivityViewController,
        context: Context
    ) {}
}
#else
struct ShareSheet: View {
    let activityItems: [Any]

    var body: some View {
        VStack(spacing: 16) {
            if let url = activityItems.compactMap({ $0 as? URL }).first {
                ShareLink(item: url) {
                    Label("Share Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            } else {
                ContentUnavailableView(
                    "Sharing Unavailable",
                    systemImage: "square.and.arrow.up",
                    description: Text("This item cannot be shared on macOS yet.")
                )
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 180)
    }
}
#endif
