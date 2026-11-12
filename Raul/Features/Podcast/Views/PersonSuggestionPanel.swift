import SwiftUI

struct PersonSuggestionPanel: View {
    let episode: Episode

    @AppStorage(LocalPersonAssociationStore.enabledKey) private var isEnabled = false
    @State private var associations: [LocalPersonAssociation] = []
    @State private var editingAssociation: LocalPersonAssociation?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var showNotes: String {
        let html = episode.desc ?? ""
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcript: String {
        (episode.transcriptLines ?? []).map(\.text).joined(separator: "\n")
    }

    private var hasSourceText: Bool {
        showNotes.isEmpty == false || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var visibleAssociations: [LocalPersonAssociation] {
        associations.filter { $0.state != .dismissed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On-device suggestions")
                .font(.subheadline.weight(.semibold))

            if isEnabled == false {
                Text("Enable “Suggest people from episode text” in Settings → Transcriptions to use this optional feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if LocalPersonAssociationStore.isModelAvailable == false {
                Text("On-device language models are not available on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hasSourceText == false {
                Text("No show notes or transcript text is available for suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await generateSuggestions() }
                } label: {
                    if isGenerating {
                        ProgressView("Reviewing episode text…")
                    } else {
                        Label("Suggest from show notes and transcript", systemImage: "person.text.rectangle")
                    }
                }
                .disabled(isGenerating)
                .font(.subheadline)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(visibleAssociations) { association in
                associationRow(association)
            }

            Text("Suggestions use episode text on this device. They are unverified, do not identify speakers from audio, and never change publisher credits.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear(perform: reload)
        .sheet(item: $editingAssociation) { association in
            PersonAssociationCorrectionSheet(association: association) { name, role in
                update(association, using: PersonAssociationPolicy.confirmed(association, correctedName: name, correctedRole: role))
            }
        }
    }

    @ViewBuilder
    private func associationRow(_ association: LocalPersonAssociation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(association.name).font(.subheadline.weight(.medium))
                if association.state == .suggested {
                    Text("Unverified")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            if association.role.isEmpty == false {
                Text(association.role).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if association.state == .suggested {
                    Button("Confirm") {
                        update(association, using: PersonAssociationPolicy.confirmed(association, correctedName: association.name, correctedRole: association.role))
                    }
                }
                Button("Correct") { editingAssociation = association }
                Button("Dismiss", role: .destructive) {
                    update(association, using: PersonAssociationPolicy.dismissed(association))
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func generateSuggestions() async {
        guard isEnabled, LocalPersonAssociationStore.isModelAvailable else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let generated = try await LocalPersonAssociationStore.suggestions(showNotes: showNotes, transcript: transcript)
            let existingNames = Set(associations.map { $0.name.lowercased() })
            associations.append(contentsOf: generated.filter { existingNames.contains($0.name.lowercased()) == false })
            LocalPersonAssociationStore.save(associations, for: episode.url)
        } catch {
            errorMessage = "Suggestions could not be generated. You can try again later."
        }
    }

    private func update(_ association: LocalPersonAssociation, using updated: LocalPersonAssociation?) {
        guard let updated,
              let index = associations.firstIndex(where: { $0.id == association.id }) else { return }
        associations[index] = updated
        LocalPersonAssociationStore.save(associations, for: episode.url)
        editingAssociation = nil
    }

    private func reload() {
        associations = LocalPersonAssociationStore.associations(for: episode.url)
    }
}

private struct PersonAssociationCorrectionSheet: View {
    let association: LocalPersonAssociation
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var role: String

    init(association: LocalPersonAssociation, onSave: @escaping (String, String) -> Void) {
        self.association = association
        self.onSave = onSave
        _name = State(initialValue: association.name)
        _role = State(initialValue: association.role)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Role", text: $role)
            }
            .navigationTitle("Correct suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, role)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
