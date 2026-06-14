//
//  PlaybackInspector.swift
//  SmartTubecontroller
//

import SwiftUI

// MARK: - Playback inspector

struct PlaybackInspector: View {
    @ObservedObject var vm: SmartTubeControllerViewModel

    var body: some View {
        Form {
            Section("Tracks") {
                formatPicker("Quality", systemImage: "4k.tv", formats: self.vm.videoFormats) { id in
                    Task { await self.vm.setVideoFormat(id) }
                }
                formatPicker("Audio", systemImage: "waveform", formats: self.vm.audioFormats) { id in
                    Task { await self.vm.setAudioFormat(id) }
                }
                subtitlePicker
            }

            Section {
                if self.vm.chapters.isEmpty {
                    Text("No chapters for the current video")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.vm.chapters) { chapter in
                        Button {
                            Task { await self.vm.seek(ms: chapter.startMs) }
                        } label: {
                            HStack(spacing: 8) {
                                if chapter.id == self.vm.currentChapter?.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(SmartTubeControllerViewModel.formatTime(chapter.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .leading)
                                Text(chapter.title ?? "Chapter")
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    Task { await self.vm.refreshChapters() }
                } label: {
                    Label("Refresh Chapters", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Chapters")
            }

#if os(macOS)
            Section("Home Theater") {
                Picker(selection: speakerBinding) {
                    Text("Home Theater").tag(true)
                    Text("TV Speakers").tag(false)
                } label: {
                    Label("Output", systemImage: "hifispeaker.2")
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await self.vm.powerToggle() }
                } label: {
                    Label("Power Toggle", systemImage: "power")
                }
            }
#endif

            Section {
                LabeledContent("TV Volume", value: "\(self.vm.theater?.volume ?? 0)")
                LabeledContent("Queue", value: "\(self.vm.queue.count) items")
                LabeledContent("Audio Output", value: self.vm.theater?.audioOutput ?? "Unknown")
            } header: {
                Text("Status")
            } footer: {
                if let error = self.vm.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var subtitlePicker: some View {
        Picker(selection: subtitleBinding) {
            Text("Off").tag(Optional<String>.none)
            ForEach(self.vm.subtitleFormats) { format in
                Text(format.title).tag(Optional(format.id))
            }
        } label: {
            Label("Subtitles", systemImage: "captions.bubble")
        }
        .disabled(self.vm.subtitleFormats.isEmpty)
    }

    private var subtitleBinding: Binding<String?> {
        Binding(
            get: { self.vm.subtitleFormats.first(where: { $0.selected })?.id },
            set: { id in Task { await self.vm.setSubtitleFormat(id) } }
        )
    }

#if os(macOS)
    private var speakerBinding: Binding<Bool> {
        Binding(
            get: { (self.vm.theater?.audioOutput ?? "").lowercased().contains("theater") },
            set: { isTheater in
                Task {
                    if isTheater { await self.vm.setHomeTheater() } else { await self.vm.setTVSpeakers() }
                }
            }
        )
    }
#endif

    private func formatPicker(_ title: String, systemImage: String, formats: [RemoteFormat], action: @escaping (String) -> Void) -> some View {
        Picker(selection: Binding(
            get: { formats.first(where: { $0.selected })?.id ?? "" },
            set: { id in if !id.isEmpty { action(id) } }
        )) {
            if formats.isEmpty {
                Text("No data").tag("")
            } else if formats.first(where: { $0.selected }) == nil {
                Text("Auto").tag("")
            }
            ForEach(formats) { format in
                Text(format.subtitle.isEmpty ? format.title : "\(format.title) · \(format.subtitle)")
                    .tag(format.id)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(formats.isEmpty)
    }

}
