import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ModelContainerLaunchView: View {
    let errorMessage: String?
    let retry: () -> Void
    @State private var copiedDiagnostics = false
    @State private var showStalledStatus = false
    @ObservedObject private var manager = ModelContainerManager.shared

    var body: some View {
        ZStack {
            AnimatedLaunchView(isFinishing: false)

            if let progress = manager.cutoverProgress, errorMessage == nil {
                VStack(spacing: 12) {
                    Text("Preparing your podcast library")
                        .font(.headline)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    if let detail = progress.detail {
                        Text(detail)
                            .font(.footnote.monospacedDigit())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    Text("This happens once. You can leave Up Next and it will continue from here when you come back.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding()
                .accessibilityElement(children: .combine)
            } else if errorMessage != nil || showStalledStatus {
                VStack(spacing: 12) {
                    if let errorMessage {
                        Text("Up Next could not open its library.")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Try Again", action: retry)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("Restoring your saved library…")
                            .font(.headline)
                        Text("Local library preparation has not finished. You can share diagnostics to help investigate.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 8) {
                        Button(copiedDiagnostics ? "Diagnostics Copied" : "Copy Diagnostics") {
                            Self.copyDiagnostics()
                            copiedDiagnostics = true
                        }
                        ShareLink(
                            item: SupportDiagnosticsRecorder.launchReport(),
                            subject: Text("Up Next Data Recovery Diagnostics")
                        ) {
                            Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding()
            }
        }
        .task(id: errorMessage == nil) {
            showStalledStatus = false
            guard errorMessage == nil else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, errorMessage == nil else { return }
            showStalledStatus = true
        }
    }

    private static func copyDiagnostics() {
        let report = SupportDiagnosticsRecorder.launchReport()
#if canImport(UIKit)
        UIPasteboard.general.string = report
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
#endif
    }
}

struct AnimatedLaunchView: View {
    let isFinishing: Bool

    // Your default 6-color palette fallback
    private static let defaultStripeColors: [Color] = [
        Color(.displayP3, red: 0.4685, green: 0.7231, blue: 0.3381, opacity: 1),
        Color(.displayP3, red: 0.9526, green: 0.7310, blue: 0.2930, opacity: 1),
        Color(.displayP3, red: 0.9033, green: 0.5332, blue: 0.2329, opacity: 1),
        Color(.displayP3, red: 0.8135, green: 0.2847, blue: 0.2712, opacity: 1),
        Color(.displayP3, red: 0.5425, green: 0.2603, blue: 0.5791, opacity: 1),
        Color(.displayP3, red: 0.2730, green: 0.6084, blue: 0.8413, opacity: 1)
    ]

    // Dynamically look up colors based on the currently chosen app icon
    fileprivate static var activeStripeColors: [Color] {
        let currentID = AlternateAppIcon.currentIdentifier
        
        // 1. Fallback if it's the primary icon
        if currentID == AlternateAppIcon.primaryID {
            return defaultStripeColors
        }
        
        // 2. Fetch the colors matching the selected icon
        guard let matchingIcon = AlternateAppIcon(id: currentID),
              !matchingIcon.previewColors.isEmpty else {
            return defaultStripeColors
        }
        
        let sourceColors = matchingIcon.previewColors
        
        // 3. If the theme naturally has 4 or more colors, use it exactly as is
        if sourceColors.count >= 4 {
            return sourceColors
        }
        
        // 4. If it has fewer than 4 colors, pad it out to exactly 4 by repeating the pattern
        return (0..<4).map { index in
            sourceColors[index % sourceColors.count]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = LaunchLayout(size: geometry.size)

            ZStack {
                LaunchBarsCurtainView(
                    layout: layout,
                    colors: Self.activeStripeColors,
                    isFinishing: isFinishing
                )

                Image("LaunchMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: layout.launchMarkWidth)
                    .shadow(color: Color.white.opacity(0.18), radius: 8, x: 0, y: 0)
                    .shadow(color: Color.black.opacity(0.22), radius: 22, x: 0, y: 12)
                    .opacity(isFinishing ? 0 : 1)
                    .scaleEffect(isFinishing ? 0.96 : 1)
                    .animation(.easeOut(duration: 0.24), value: isFinishing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

private struct LaunchLayout {
    let size: CGSize

    var launchMarkWidth: CGFloat {
        min(size.width * 0.28, 140)
    }
}

private struct LaunchBarsCurtainView: View {
    let layout: LaunchLayout
    let colors: [Color]
    let isFinishing: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(1), color],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                /*
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: max(1, bandHeight(for: index) * 0.08))
                    }*/
                    .frame(width: layout.size.width, height: bandHeight(for: index))
                    .offset(y: bandOrigin(for: index) + travelOffset(for: index))
                    .shadow(color: color.opacity(0.14), radius: 12, x: 0, y: 6)
                    .animation(
                        .easeInOut(duration: 0.72).delay(Double(index) * 0.06),
                        value: isFinishing
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func bandHeight(for index: Int) -> CGFloat {
        bandOrigin(for: index + 1) - bandOrigin(for: index)
    }

    private func bandOrigin(for index: Int) -> CGFloat {
        floor(CGFloat(index) * layout.size.height / CGFloat(colors.count))
    }

    private func travelOffset(for index: Int) -> CGFloat {
        guard isFinishing else { return 0 }
        return -layout.size.height - CGFloat(index) * 18
    }
}

#Preview {
    AnimatedLaunchView(isFinishing: false)
}
