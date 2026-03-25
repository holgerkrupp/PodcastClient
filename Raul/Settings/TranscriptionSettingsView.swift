import SwiftUI
import SwiftData
import Speech

struct TranscriptionSettingsView: View {
    @Query(sort: [SortDescriptor(\TranscriptionRecord.finishedAt, order: .reverse)])
    private var recentRecords: [TranscriptionRecord]

    @State private var supportedLocales: [Locale] = []
    @State private var installedLocales: [Locale] = []

    var body: some View {
        List {
            Section("On-Device Transcription") {
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
