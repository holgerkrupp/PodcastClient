import SwiftUI

enum OnboardingPreferenceKeys {
    static let didCompleteOnboarding = "didCompleteOnboarding"
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to Up Next",
            summary: "Up Next helps you collect new podcast episodes, choose what is worth hearing, and keep one clear playback list.",
            systemImage: "play.circle.fill",
            tint: .accentColor,
            bullets: [
                "Subscribe to podcasts from search, categories, hot podcasts, or an OPML import.",
                "Fresh episodes arrive in Inbox first unless your settings send them directly to a playlist.",
                "The player follows your playlist order and keeps playback ready across the app."
            ]
        ),
        OnboardingPage(
            title: "Subscribe",
            summary: "Use Add to find shows by name, paste a feed URL, browse categories, or import your subscriptions.",
            systemImage: "plus.circle.fill",
            tint: .green,
            bullets: [
                "Open Add from the tab bar.",
                "Search for a podcast or paste its RSS feed URL.",
                "Tap Subscribe to add the show to your library and start receiving episodes."
            ]
        ),
        OnboardingPage(
            title: "Inbox",
            summary: "Inbox is the calm sorting place for new episodes before they join your listening queue.",
            systemImage: "tray.fill",
            tint: .orange,
            bullets: [
                "Review newly found episodes without cluttering your playlist.",
                "Move episodes you want to hear into a playlist.",
                "Archive anything you want out of sight."
            ]
        ),
        OnboardingPage(
            title: "Playlists",
            summary: "Playlists decide what plays next. Keep one main Up Next queue or create separate lists for different moods.",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            tint: .blue,
            bullets: [
                "Add episodes from Inbox, Library, or podcast detail screens.",
                "Reorder episodes manually when your listening priorities change.",
                "Use Settings to choose where new episodes from subscriptions should go."
            ]
        )
    ]

    var body: some View {
        NavigationStack {
            TabView {
                ForEach(pages) { page in
                    OnboardingPageView(page: page)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle("Getting Started")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Start Listening")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.thinMaterial)
            }
        }
    }
}

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let systemImage: String
    let tint: Color
    let bullets: [String]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 76, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(page.tint)
                    .frame(width: 120, height: 120)
                    .background(page.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.top, 34)

                VStack(spacing: 10) {
                    Text(page.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text(page.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.bullets, id: \.self) { bullet in
                        Label {
                            Text(bullet)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(page.tint)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Spacer(minLength: 90)
            }
            .padding(.horizontal, 24)
        }
    }
}

#Preview {
    OnboardingView()
}
