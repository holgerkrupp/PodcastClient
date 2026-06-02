import SwiftUI

struct WatchStorageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WatchSyncStore

  /*  private let storageOptions: [Int64] = [
        128, 256, 512, 1024, 2048
    ].map { Int64($0) * 1_024 * 1_024 }
   */
    private let storageOptions: [Int64] = [
        100000000, 200000000, 500000000, 1000000000, 2000000000
    ]

    var body: some View {
        Form {
            Section("Playback") {
                Toggle(
                    "Remote Control iPhone",
                    isOn: Binding(
                        get: { store.storageSettings.playbackMode == .remotePhone },
                        set: { store.setPlaybackMode($0 ? .remotePhone : .local) }
                    )
                )

                Text(store.storageSettings.playbackMode == .remotePhone ? "Playback controls manage the iPhone app." : "Playback uses files and streams on the watch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

            if WatchCellularSupport.canUseCellularDownloads {
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
        }
        .navigationTitle("Settings")
        .tint(.upNextAccent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

#if DEBUG
#Preview("Watch Storage Settings") {
    NavigationStack {
        WatchStorageSettingsView()
            .environmentObject(WatchSyncStore.preview())
    }
}
#endif
