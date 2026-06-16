//
//  SettingsSheets.swift
//  SmartTubecontroller
//

import SwiftUI

// MARK: - Connection settings sheet

struct ConnectionSettingsSheet: View {
    @ObservedObject var vm: SmartTubeControllerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("SmartTube API") {
                    TextField("Host", text: self.$vm.host)
                    TextField("Port", text: self.$vm.apiPort)
                    LabeledContent("Token", value: self.vm.redactedToken)
                }
                if !self.vm.knownDevices.isEmpty {
                    Section("Known TVs") {
                        ForEach(self.vm.knownDevices) { device in
                            Button {
                                self.vm.host = device.host
                                self.vm.apiPort = String(device.port)
                                self.vm.saveSettings()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                        Text("\(device.host):\(device.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if device.host == self.vm.host && device.port == self.vm.apiPortInt {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    TextField("TV IP (blank = same as API host)", text: self.$vm.bridgeHost)
                    TextField("ADB Port", text: self.$vm.bridgePort)
                    Picker("ADB Device", selection: self.$vm.selectedADBSerial) {
                        Text("Auto").tag("")
                        ForEach(self.vm.adbDevices, id: \.serial) { device in
                            Text("\(device.serial) (\(device.state))").tag(device.serial)
                        }
                    }
                    .onChange(of: self.vm.selectedADBSerial) { _, _ in
                        self.vm.saveSettings()
                    }
                    Button("Refresh ADB Devices") {
                        Task { await self.vm.refreshADBDevices() }
                    }
                    Button("Reconnect ADB") {
                        Task { await self.vm.connectBridgeIfPossible() }
                    }
                    Text(self.vm.bridgePhase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("ADB (Home Theater)")
                } footer: {
                    Text("Controls the TV's home-theater (subwoofer, rear, sound mode) over the network on port 5555.")
                        .font(.caption)
                }
                Section {
                    Toggle("Player volume as secondary control", isOn: self.$vm.playerVolumeEnabled)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Shows a second slider for the player's internal volume (pre-amp gain). TV volume remains the primary control.")
                        .font(.caption)
                }
                Section {
                    Button("Connect & Pair") {
                        Task { await self.vm.manualConnect() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { self.dismiss() }
                    .platformKeyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 560)
        .task {
            await self.vm.refreshADBDevices()
        }
    }
}

// MARK: - Activity log sheet

struct ActivityLogSheet: View {
    @ObservedObject var vm: SmartTubeControllerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.headline)
                Spacer()
                Button("Copy") { self.vm.copyLogs() }
                Button("Done") { self.dismiss() }
                    .platformKeyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(self.vm.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 560, height: 460)
    }
}

#Preview {
    ContentView()
}
