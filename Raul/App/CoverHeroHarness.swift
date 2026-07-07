// TEMPORARY visual-debug harness for the ESADesignKit coverHero. Rendered only
// when the app is launched with `-coverHeroHarness` (optionally `-harnessCase N`).
// Delete after verification.
#if DEBUG
import SwiftUI
import ESADesignKit
#if canImport(UIKit)
import UIKit
#endif

private func makeSquareCoverData() -> Data {
    let size = CGSize(width: 400, height: 400)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { ctx in
        UIColor.systemIndigo.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        UIColor.white.setStroke()
        let path = UIBezierPath()
        path.lineWidth = 12
        path.move(to: CGPoint(x: 40, y: 40))
        path.addLine(to: CGPoint(x: 360, y: 360))
        path.move(to: CGPoint(x: 360, y: 40))
        path.addLine(to: CGPoint(x: 40, y: 360))
        path.stroke()
    }
    return image.pngData() ?? Data()
}

/// Writes the square cover to a temp file and returns its URL, so `.url` sources
/// resolve offline exactly like a remote cover would.
private func squareCoverURL() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("harness_square.png")
    try? makeSquareCoverData().write(to: url)
    return url
}

extension View {
    @ViewBuilder
    func coverHeroHarnessOverride() -> some View {
        if CommandLine.arguments.contains("-coverHeroHarness") {
            CoverHeroHarness()
        } else {
            self
        }
    }
}

struct CoverHeroHarness: View {
    private let coverURL = squareCoverURL()

    private var harnessCase: Int {
        if let index = CommandLine.arguments.firstIndex(of: "-harnessCase"),
           index + 1 < CommandLine.arguments.count,
           let value = Int(CommandLine.arguments[index + 1]) {
            return value
        }
        return 0
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Harness \(harnessCase)")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch harnessCase {
        case 1:
            // Replicates EpisodeDetailView: ZStack + ScrollView + .url source + ESAFullBackground.
            ZStack {
                ScrollView {
                    rows
                }
                .coverHero(image: .url(coverURL), title: "Square Cover Hero")
            }
            .ESAFullBackground(image: coverURL)
        case 2:
            // Replicates PodcastDetailView: List + .url source + ESAFullBackground.
            List {
                ForEach(0..<24) { index in
                    Text("Content row \(index)")
                        .listRowBackground(Color.clear)
                }
            }
            .coverHero(image: .url(coverURL), title: "Square Cover Hero")
            .ESAFullBackground(image: coverURL)
            .listStyle(PlainListStyle())
        case 3:
            // Async .url source alone (no ZStack / no ESAFullBackground).
            ScrollView {
                rows
            }
            .coverHero(image: .url(coverURL), title: "Square Cover Hero")
        case 4:
            // ZStack + ESAFullBackground with a SYNCHRONOUS imageData source.
            ZStack {
                ScrollView {
                    rows
                }
                .coverHero(imageData: makeSquareCoverData(), title: "Square Cover Hero")
            }
            .ESAFullBackground(image: coverURL)
        case 5:
            // Async .url source but with placeholderAspectRatio matching square art.
            ScrollView {
                rows
            }
            .coverHero(image: .url(coverURL), title: "Square Cover Hero", placeholderAspectRatio: 1.0)
        default:
            // Baseline: plain ScrollView + imageData source (known good).
            ScrollView {
                rows
            }
            .coverHero(imageData: makeSquareCoverData(), title: "Square Cover Hero")
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(0..<24) { index in
                Text("Content row \(index)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}
#endif
