//
//  PlaylistSymbolGridPicker.swift
//  Raul
//

import SwiftUI

/// The playlist icon chooser, shared by playlist creation and playlist settings.
struct PlaylistSymbolGridPicker: View {
    @Binding var selection: String

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 56, maximum: 70), spacing: 10)
    ]

    var body: some View {
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
    }
}
