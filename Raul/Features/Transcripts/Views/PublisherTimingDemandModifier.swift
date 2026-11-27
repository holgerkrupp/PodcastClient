//
//  PublisherTimingDemandModifier.swift
//  Raul
//
//  Marks a publisher transcript as visible so the player enriches its word
//  timing automatically while that episode plays from a downloaded file
//  (#490). Pass nil for transcripts that are not publisher-provided.
//

import SwiftUI

private struct PublisherTimingDemandModifier: ViewModifier {
    let episodeURL: URL?
    @State private var registeredURL: URL?

    func body(content: Content) -> some View {
        content
            .onAppear { register(episodeURL) }
            .onDisappear { register(nil) }
            .onChange(of: episodeURL) { _, newValue in register(newValue) }
    }

    private func register(_ url: URL?) {
        guard url != registeredURL else { return }
        let store = TranscriptSynchronizationStore.shared
        if let registeredURL { store.endTimingDemand(for: registeredURL) }
        registeredURL = url
        if let url { store.beginTimingDemand(for: url) }
    }
}

extension View {
    /// Requests automatic publisher word-timing enrichment while visible.
    func publisherTimingDemand(episodeURL: URL?) -> some View {
        modifier(PublisherTimingDemandModifier(episodeURL: episodeURL))
    }
}
