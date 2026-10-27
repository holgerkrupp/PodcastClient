//
//  PlaylistSymbolGridPicker.swift
//  Raul
//

import SwiftUI

/// The playlist icon chooser, shared by playlist creation and playlist settings.
struct PlaylistSymbolGridPicker: View {
    @Binding var selection: String

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 80, maximum: 105), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Playlist.symbolOptions(including: selection)) { option in
                Button {
                    selection = option.symbolName
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.symbolName)
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text(option.title)
                            .font(.caption2)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.center)
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selection == option.symbolName ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selection == option.symbolName ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(option.title == "Current"
                                    ? "Current playlist icon, \(option.symbolName)"
                                    : "Playlist icon \(option.title)")
                .accessibilityAddTraits(selection == option.symbolName ? .isSelected : [])
                .accessibilityIdentifier("playlistIcon.\(option.symbolName)")
            }
        }
    }
}
