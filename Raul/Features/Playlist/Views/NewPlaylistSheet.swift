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
                    TextField("Match text", text: $rule.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#else
                    TextField("Match text", text: $rule.query)
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
}
