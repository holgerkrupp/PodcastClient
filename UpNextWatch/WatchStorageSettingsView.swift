import SwiftUI

struct WatchStorageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WatchSyncStore

    private let storageOptions: [Int64] = [
        128, 256, 512, 1024, 2048
    ].map { Int64($0) * 1_024 * 1_024 }

    var body: some View {
        Form {
            Section("Storage") {
                Picker(
                    "Limit",
                    selection: Binding(
                        get: { store.storageSettings.maxStorageBytes },
                        set: { store.setMaxStorageBytes($0) }
                    )
                ) {
                    ForEach(storageOptions, id: \.self) { option in
                        Text(ByteCountFormatter.string(fromByteCount: option, countStyle: .file))
                            .tag(option)
                    }
                }

                Text("Currently using \(store.usedStorageDescription).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("When the limit is full, Up Next still shows the episode but asks before downloading it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                Toggle(
                    "Allow Cellular Downloads",
                    isOn: Binding(
                        get: { store.storageSettings.allowCellularDownloads },
                        set: { store.setAllowCellularDownloads($0) }
                    )
                )
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
