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
