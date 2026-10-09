//
//  PlaylistSymbolGridPicker.swift
//  Raul
//

import SwiftUI
import SFSymbolSelector

/// The playlist icon chooser, shared by playlist creation and playlist settings.
struct PlaylistSymbolGridPicker: View {
    @Binding var selection: String

    /// A focused podcast set appears first in the full selector; the package
    /// catalog keeps the rest of SF Symbols available without a growing grid.
    private static let podcastSymbols = [
        "arrow.down.circle.fill", "tray.and.arrow.down.fill", "checkmark.circle.fill",
        "play.circle.fill", "pause.circle.fill", "waveform", "headphones",
        "clock.arrow.circlepath", "calendar.badge.clock", "timer",
        "text.book.closed.fill", "quote.bubble.fill", "globe", "antenna.radiowaves.left.and.right",
        "list.bullet.rectangle", "rectangle.stack.fill", "line.3.horizontal.decrease.circle.fill",
        "sparkles", "newspaper.fill", "mic.fill", "person.2.fill", "bookmark.fill",
        "star.fill", "heart.fill", "car.fill", "moon.fill", "sun.max.fill"
    ]

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 56, maximum: 70), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Playlist.symbolOptions) { option in
                    Button {
                        selection = option.symbolName
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: option.symbolName)
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                            Text(option.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selection == option.symbolName ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selection == option.symbolName ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Playlist icon \(option.title)")
                    .accessibilityAddTraits(selection == option.symbolName ? .isSelected : [])
                }
            }

            SFSymbolSelector(
                selection: $selection,
                suggestedSymbolName: selection,
                symbols: Self.podcastSymbols
                    + Playlist.symbolOptions.map(\.symbolName)
                    + SFSymbolCatalog.commonSymbols
            )
        }
    }
}
