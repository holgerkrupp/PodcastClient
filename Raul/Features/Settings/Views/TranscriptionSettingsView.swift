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
    @State private var queueEntries: [TranscriptionQueueEntry] = []

    private var globalSettings: PodcastSettings? {
        defaultSettings.first
    }

    /// Re-arms the background transcription pass so a changed setting takes
    /// effect now instead of at the next background transition.
    private func rescheduleAutomaticTranscriptionProcessing() {
#if canImport(UIKit)
        Task {
            await AppDelegate.scheduleAutomaticTranscriptionProcessingIfNeeded()
        }
#endif
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
                                rescheduleAutomaticTranscriptionProcessing()
                            }
                        )
                    )
                    .disabled(globalSettings.enableTranscriptions == false)

                    Toggle(
                        "Only while charging",
                        isOn: Binding(
                            get: { globalSettings.limitAutomaticOnDeviceTranscriptionsToCharging },
                            set: { newValue in
                                globalSettings.limitAutomaticOnDeviceTranscriptionsToCharging = newValue
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                                rescheduleAutomaticTranscriptionProcessing()
                            }
                        )
                    )
                    .disabled(globalSettings.enableTranscriptions == false || globalSettings.enableAutomaticOnDeviceTranscriptions == false)

                    Stepper(
                        value: Binding(
                            get: { min(max(globalSettings.transcriptionMaxSnippetDurationSeconds, 0.4), 8.0) },
                            set: { newValue in
                                globalSettings.transcriptionMaxSnippetDurationSeconds = min(max(newValue, 0.4), 8.0)
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        ),
                        in: 0.4...8.0,
                        step: 0.1
                    ) {
                        LabeledContent("Max snippet length") {
                            Text("\(globalSettings.transcriptionMaxSnippetDurationSeconds, specifier: "%.1f")s")
                                .monospacedDigit()
                        }
                    }
                    .disabled(globalSettings.enableTranscriptions == false)
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
                Text("When enabled, the app can start on-device transcription automatically after downloads finish. Podcasts that publish their own transcripts are never transcribed on device — their transcript is imported instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Use \"Only while charging\" if you want automatic local transcription to wait for external power. While the app is open it reacts to charging changes, and in the background it works through your playlists whenever the device has a free moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Models are language-specific on-device speech assets. The app uses the episode language when available and falls back to the current device locale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Shorter snippets follow playback more closely and are better for word-level highlighting, but they create more transcript rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript Synchronization") {
                if let globalSettings {
                    Toggle(
                        "Automatically synchronize publisher transcripts",
                        isOn: Binding(
                            get: { globalSettings.enablePublisherTranscriptSynchronization },
                            set: { enabled in
                                globalSettings.enablePublisherTranscriptSynchronization = enabled
                                context.saveIfNeeded()
                                TranscriptSynchronizationStore.shared.setEnabled(enabled)
                                if enabled == false {
                                    TranscriptSynchronizationStore.shared.clearActiveTimelines()
                                }
                                Task {
                                    await TranscriptSynchronizationService.shared.setEnabled(enabled)
#if os(iOS)
                                    await AppDelegate.schedulePublisherTranscriptSynchronizationIfNeeded()
#endif
                                }
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )

                    Toggle(
                        "Add likely ad breaks to the chapter list",
                        isOn: Binding(
                            get: { globalSettings.createTranscriptGapChapters },
                            set: { enabled in
                                globalSettings.createTranscriptGapChapters = enabled
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )

                    Toggle(
                        "Automatically skip transcript-gap chapters",
                        isOn: Binding(
                            get: { globalSettings.automaticallySkipTranscriptGapChapters },
                            set: { enabled in
                                globalSettings.automaticallySkipTranscriptGapChapters = enabled
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )
                }
                Text("Gap chapters are added only after multiple confident matches identify inserted audio. They may be ads or other audio absent from the publisher transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Automatic skipping applies to every transcript-gap chapter. Review their boundaries in the chapter list; you can also skip individual chapters there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("After a download, the app queues short audio samples for analysis when iOS allows background work, usually while the device is charging and idle. iOS may delay or stop the work; playback analysis fills in later if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Compare small portions of podcast audio with publisher transcripts to correct caption timing when ads or other audio have been inserted. Processing happens on device and may use additional battery. Your transcript text stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only publisher-provided transcripts are eligible. On-device AI transcripts and transcripts with unknown origin are left unchanged. Turning this off immediately restores original transcript timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advertisement Detection") {
                if let globalSettings {
                    Toggle(
                        "Detect advertisements",
                        isOn: Binding(
                            get: { globalSettings.enableAdvertisementDetection },
                            set: { newValue in
                                globalSettings.enableAdvertisementDetection = newValue
                                if newValue == false {
                                    globalSettings.showDetectedAdvertisements = false
                                    globalSettings.enableAutomaticAdvertisementSkipping = false
                                }
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )

                    Toggle(
                        "Show detected advertisements",
                        isOn: Binding(
                            get: { globalSettings.showDetectedAdvertisements },
                            set: { newValue in
                                globalSettings.showDetectedAdvertisements = newValue
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )
                    .disabled(globalSettings.enableAdvertisementDetection == false)

                    Toggle(
                        "Automatically skip high-confidence advertisements",
                        isOn: Binding(
                            get: { globalSettings.enableAutomaticAdvertisementSkipping },
                            set: { newValue in
                                globalSettings.enableAutomaticAdvertisementSkipping = newValue
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )
                    .disabled(globalSettings.enableAdvertisementDetection == false)
                }

                Text("Detection runs on device and keeps evidence separate from publisher chapters. Showing a range never changes playback; automatic skipping is a separate opt-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Generated Chapters") {
                if let globalSettings {
                    Toggle(
                        "Automatically generate chapters when publisher chapters are unavailable",
                        isOn: Binding(
                            get: { globalSettings.automaticallyGenerateChaptersWhenUnavailable },
                            set: { newValue in
                                globalSettings.automaticallyGenerateChaptersWhenUnavailable = newValue
                                context.saveIfNeeded()
                                NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
                            }
                        )
                    )
                }
                Text("Generated editorial chapters use the on-device transcript model. Confirmed detected advertisements are added as separate chapters and never enable ad skipping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Captions & Audio Descriptions") {
                Text("Episode transcripts are used as captions inside the player and transcript screens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This app plays spoken-word audio and does not include separate audio-description tracks. Chapter titles and transcripts provide descriptive context instead.")
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

            Section("Current Transcriptions") {
                if queueEntries.isEmpty {
                    Text("Nothing is currently transcribing or queued.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(queueEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.episodeTitle)
                                    .font(.headline)
                                    .lineLimit(2)
                                Spacer()
                                queueStateLabel(for: entry)
                            }
                            if let podcastTitle = entry.podcastTitle, podcastTitle.isEmpty == false {
                                Text(podcastTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if case let .queued(position) = entry.state, position > 1 {
                                Button("Move to Next") {
                                    Task {
                                        await TranscriptionManager.shared.moveToFrontOfQueue(
                                            episodeURL: entry.episodeURL
                                        )
                                        await refreshQueue()
                                    }
                                }
                                .font(.caption.weight(.semibold))
                            }
                            Button(role: .destructive) {
                                Task {
                                    await TranscriptionManager.shared.cancel(episodeURL: entry.episodeURL)
                                    await refreshQueue()
                                }
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityLabel("Cancel transcription")
                        }
                        .padding(.vertical, 3)
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
                                Text("\(record.processingShareOfEpisodeDuration, format: .percent.precision(.fractionLength(0))) of episode length")
                            }
                            .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Transcriptions")
        .onAppear {
            CrashBreadcrumbs.shared.record("transcription_settings_on_appear")
        }
        .task {
            CrashBreadcrumbs.shared.record("transcription_settings_task_started")
            await PodcastSettingsModelActor(modelContainer: context.container).ensureStandardSettingsExists()
            supportedLocales = await SpeechTranscriber.supportedLocales.sorted {
                $0.identifier(.bcp47) < $1.identifier(.bcp47)
            }
            installedLocales = await Array(SpeechTranscriber.installedLocales).sorted {
                $0.identifier(.bcp47) < $1.identifier(.bcp47)
            }
            CrashBreadcrumbs.shared.record(
                "transcription_settings_task_completed",
                details: "supported=\(supportedLocales.count),installed=\(installedLocales.count)"
            )
        }
        .task {
            repeat {
                await refreshQueue()
                try? await Task.sleep(for: .seconds(1))
            } while Task.isCancelled == false
        }
    }

    @ViewBuilder
    private func queueStateLabel(for entry: TranscriptionQueueEntry) -> some View {
        switch entry.state {
        case .active:
            Label("Active", systemImage: "waveform")
                .foregroundStyle(.green)
        case .queued(let position):
            Text(position == 1 ? "Next" : "#\(position)")
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func refreshQueue() async {
        queueEntries = await TranscriptionManager.shared.queueEntries()
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
