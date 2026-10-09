//
//  NewPlaylistSheet.swift
//  Raul
//

import SwiftUI

struct NewPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft = PlaylistCreationDraft()

    let onCreate: (PlaylistCreationDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Name", text: $draft.name)
                    Picker("Type", selection: $draft.kind) {
                        Text("Manual").tag(Playlist.Kind.manual)
                        Text("Smart").tag(Playlist.Kind.smart)
                    }
                }

                if draft.kind == .smart {
                    Section("Examples") {
                        Picker("Start with", selection: $draft.example) {
                            Text("Blank").tag(SmartPlaylistExample?.none)
                            ForEach(SmartPlaylistExample.allCases, id: \.self) { example in
                                Text(example.title).tag(Optional(example))
                            }
                        }
                        .onChange(of: draft.example) { _, example in
                            guard let example else { return }
                            draft.name = example.title
                            draft.symbolName = example.symbol
                            draft.smartFilter = example.filter
                        }
                    }
                    SmartPlaylistFilterEditor(filter: $draft.smartFilter)
                }

                Section("Icon") {
                    PlaylistSymbolGridPicker(selection: $draft.symbolName)
                }
            }
            .navigationTitle("New Playlist")
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(draft)
                        dismiss()
                    }
                    .disabled(canCreate == false)
                }
            }
        }
    }

    private var canCreate: Bool {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct PlaylistCreationDraft {
    var name: String = ""
    var symbolName: String = Playlist.defaultManualSymbolName
    var kind: Playlist.Kind = .manual
    var smartFilter = SmartPlaylistFilter()
    var example: SmartPlaylistExample? = nil
}

enum SmartPlaylistExample: String, CaseIterable, Hashable {
    case offlineCommute, shortEpisodes, freshNews, germanListening, deepDive, continueListening
    var title: String {
        switch self {
        case .offlineCommute: "Offline Commute"
        case .shortEpisodes: "Short Episodes"
        case .freshNews: "Fresh News"
        case .germanListening: "German Listening"
        case .deepDive: "Deep Dive"
        case .continueListening: "Continue Listening"
        }
    }
    var symbol: String {
        switch self {
        case .offlineCommute: "car"
        case .shortEpisodes: "bolt"
        case .freshNews: "newspaper"
        case .germanListening: "globe"
        case .deepDive: "book"
        case .continueListening: "arrow.uturn.backward"
        }
    }
    var filter: SmartPlaylistFilter {
        func rule(_ field: SmartPlaylistField, _ comparator: SmartPlaylistComparator = .equals, _ value: String) -> SmartPlaylistRule {
            SmartPlaylistRule(field: field, comparator: comparator, query: value)
        }
        var result = SmartPlaylistFilter()
        switch self {
        case .offlineCommute:
            result.rules = [rule(.downloaded, .equals, "Yes"), rule(.status, .equals, "Unplayed"), rule(.duration, .lessThan, "30")]
        case .shortEpisodes:
            result.rules = [rule(.duration, .lessThan, "20"), rule(.status, .equals, "Unplayed")]
        case .freshNews:
            result.rules = [rule(.category, .equals, "News"), rule(.published, .withinLastDays, "2"), rule(.status, .equals, "Unplayed")]
        case .germanListening:
            result.rules = [rule(.language, .equals, "de"), rule(.status, .equals, "Unplayed")]
        case .deepDive:
            result.rules = [rule(.duration, .greaterThan, "60")]
        case .continueListening:
            result.rules = [rule(.status, .equals, "In Progress")]
        }
        return result
    }
}

struct SmartPlaylistFilterEditor: View {
    @Binding var filter: SmartPlaylistFilter

    var body: some View {
        Section("Smart Filters") {
            Picker("Match", selection: $filter.matchMode) {
                ForEach(SmartPlaylistMatchMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Toggle("Downloaded episodes only", isOn: $filter.requireDownloaded)
            Toggle("Include archived episodes", isOn: $filter.includeArchived)

            ForEach($filter.rules) { $rule in
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Field", selection: $rule.field) {
                        ForEach(SmartPlaylistField.allCases, id: \.self) { field in
                            Text(field.displayName).tag(field)
                        }
                    }
                    Picker("Condition", selection: $rule.comparator) {
                        ForEach(SmartPlaylistComparator.allCases, id: \.self) { comparator in
                            Text(comparator.displayName).tag(comparator)
                        }
                    }
#if os(iOS)
                    TextField(valuePlaceholder(for: rule.field), text: $rule.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#else
                    TextField(valuePlaceholder(for: rule.field), text: $rule.query)
                        .autocorrectionDisabled()
#endif
                    Button("Remove Filter", systemImage: "minus.circle", role: .destructive) {
                        filter.rules.removeAll { $0.id == rule.id }
                    }
                }
                .padding(.vertical, 4)
            }

            Button("Add Filter", systemImage: "plus.circle") {
                filter.rules.append(SmartPlaylistRule(field: .episodeTitle, query: ""))
            }
        }
    }

    private func valuePlaceholder(for field: SmartPlaylistField) -> String {
        switch field {
        case .downloaded, .archived: "Yes or No"
        case .duration: "Minutes"
        case .published: "Days (or ISO date)"
        case .status: "Unplayed, In Progress, Played"
        case .episodeType: "Full, Bonus, Trailer"
        case .source: "Feed or Sideloaded"
        case .language: "Language, e.g. de or en"
        case .category: "Feed category"
        default: "Match text"
        }
    }
}
