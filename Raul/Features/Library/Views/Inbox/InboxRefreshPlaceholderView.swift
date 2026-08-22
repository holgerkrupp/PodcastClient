import SwiftUI

/// Shown instead of ``InboxEmptyView`` while a refresh is still running and no
/// episode has arrived yet. New episodes are published feed by feed, so an empty
/// list during a refresh means "nothing yet", not "nothing at all".
struct InboxRefreshPlaceholderView: View {
    let completed: Int
    let total: Int

    var body: some View {
        VStack(spacing: 12) {
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
            } else {
                ProgressView()
            }

            Text("Checking for new episodes")
                .font(.headline)

            if total > 0 {
                Text("\(completed) of \(total) podcasts checked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("New episodes appear here as soon as their podcast has been checked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    InboxRefreshPlaceholderView(completed: 3, total: 12)
}
