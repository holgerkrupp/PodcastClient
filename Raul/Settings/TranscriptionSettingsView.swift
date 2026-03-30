import SwiftUI
import SwiftData
import Speech

struct TranscriptionSettingsView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" })
    private var defaultSettings: [PodcastSettings]

    @Query(sort: [SortDescriptor(\TranscriptionRecord.finishedAt, order: .reverse)])
    private var recentRecords: [TranscriptionRecord]

    @State private var supportedLocales: [Locale] = []
    @State private var installedLocales: [Locale] = []

    private var globalSettings: PodcastSettings? {
        defaultSettings.first
    }

    var body: some View {
        List {
            Section("On-Device Transcription") {
                if let globalSettings {
                    Toggle(
                        "Automatic on-device transcriptions",
                        isOn: Binding(
                            get: { globalSettings.enableAutomaticOnDeviceTranscriptions },
                            set: { newValue in
                                globalSettings.enableAutomaticOnDeviceTranscriptions = newValue
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )

                    Toggle(
                        "Only while charging",
                        isOn: Binding(
                            get: { globalSettings.limitAutomaticOnDeviceTranscriptionsToCharging },
                            set: { newValue in
                                globalSettings.limitAutomaticOnDeviceTranscriptionsToCharging = newValue
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )
                    .disabled(globalSettings.enableAutomaticOnDeviceTranscriptions == false)
                }
                LabeledContent("Engine") {
                    Text("Apple SpeechTranscriber")
                }
                LabeledContent("Preset") {
                    Text("Transcription")
                }
                LabeledContent("Installed Models") {
                    Text(installedLocales.isEmpty ? "None" : "\(installedLocales.count)")
                }
                LabeledContent("Supported Models") {
                    Text(supportedLocales.isEmpty ? "Loading…" : "\(supportedLocales.count)")
                }
                Text("When enabled, the app can start on-device transcription automatically after downloads finish. Feed-provided transcripts are still preferred when available, and the manual Transcribe button remains available even when this is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use \"Only while charging\" if you want automatic local transcription to wait for external power. While the app is open it reacts to charging changes, and in the background it can pick up eligible Up Next episodes once power is available. Manual transcription is still unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Models are language-specific on-device speech assets. The app uses the episode language when available and falls back to the current device locale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if installedLocales.isEmpty == false {
                Section("Installed Models") {
                    ForEach(installedLocales.map { $0.identifier(.bcp47) }, id: \.self) { identifier in
                        Text(identifier)
                            .monospaced()
                    }
                }
            }

            Section("Recent Transcriptions") {
                if recentRecords.isEmpty {
                    ContentUnavailableView(
                        "No Transcriptions Yet",
                        systemImage: "waveform.and.mic",
                        description: Text("Recent on-device transcriptions will appear here once you create one.")
                    )
                } else {
                    ForEach(recentRecords.prefix(20)) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.episodeTitle)
                                .font(.headline)
                                .lineLimit(2)

                            if let podcastTitle = record.podcastTitle, podcastTitle.isEmpty == false {
                                Text(podcastTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                Label(record.localeIdentifier, systemImage: "globe")
                                Spacer()
                                Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            HStack {
                                Label(record.transcriptionDuration.formattedAsUnits, systemImage: "timer")
                                Spacer()
                                Label(record.audioDuration.formattedAsUnits, systemImage: "waveform")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            HStack {
                                Text(String(format: "%.2fx realtime", record.speedRelativeToRealtime))
                                Spacer()
                                Text(String(format: "%.0f%% of episode length", record.processingShareOfEpisodeDuration * 100))
                            }
                            .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Transcriptions")
        .task {
            await PodcastSettingsModelActor(modelContainer: context.container).ensureStandardSettingsExists()
            supportedLocales = await SpeechTranscriber.supportedLocales.sorted {
                $0.identifier(.bcp47) < $1.identifier(.bcp47)
            }
            installedLocales = await Array(SpeechTranscriber.installedLocales).sorted {
                $0.identifier(.bcp47) < $1.identifier(.bcp47)
            }
        }
    }
}

private extension Double {
    var formattedAsUnits: String {
        Duration.seconds(self).formatted(.units(width: .narrow))
    }
}

#Preview {
    NavigationStack {
        TranscriptionSettingsView()
    }
}
