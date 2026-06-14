//
//  ContentView.swift
//  SmartTubecontroller
//
//  Unified macOS player-style controller for SmartTube Remote API + ADB Bridge.
//  Requires SmartTubeSDK.swift and SmartTubeADBBridge.swift in the same Xcode target.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = SmartTubeControllerViewModel()
    @State private var showInspector = true
    @State private var showSettings = false
    @State private var showLogs = false

    var body: some View {
        NavigationSplitView {
            QueueSidebar(vm: self.vm)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            NowPlayingView(vm: self.vm)
                .frame(minWidth: 420, minHeight: 480)
        }
        .navigationTitle("SmartTube")
        .platformNavigationSubtitle(self.vm.player?.video?.title ?? "")
        .inspector(isPresented: self.$showInspector) {
            PlaybackInspector(vm: self.vm)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ConnectionStatus(vm: self.vm)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if self.vm.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await self.vm.autoConnect() }
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                .platformHelp("Auto-connect and pair")
                .platformKeyboardShortcut("r", modifiers: [.command])

                Menu {
                    Button("Connection Settings…") { self.showSettings = true }
                    Button("Reconnect Manually") { Task { await self.vm.manualConnect() } }
                    Divider()
                    Button("Show Activity Log…") { self.showLogs = true }
                    Button("Copy Logs") { self.vm.copyLogs() }
                    Button("Copy Diagnostics") { self.vm.copyDiagnostics() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                Button {
                    self.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .platformHelp("Toggle the playback inspector")
            }
        }
        .sheet(isPresented: self.$showSettings) {
            ConnectionSettingsSheet(vm: self.vm)
        }
        .sheet(isPresented: self.$showLogs) {
            ActivityLogSheet(vm: self.vm)
        }
        .task {
            await self.vm.autoConnect()
        }
    }
}

// MARK: - Connection status (toolbar)

private struct ConnectionStatus: View {
    @ObservedObject var vm: SmartTubeControllerViewModel

    var body: some View {
        HStack(spacing: 7) {
            indicator("API", active: self.vm.isAPIConnected, help: "SmartTube REST API")
            indicator("Live", active: self.vm.isRealtimeConnected, help: "Realtime WebSocket")
#if os(macOS)
            indicator("ADB", active: self.vm.isBridgeConnected, help: "ADB bridge")
#endif
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(.quaternary.opacity(0.6))
        )
        .fixedSize()
    }

    private func indicator(_ title: String, active: Bool, help: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .platformHelp("\(help): \(active ? "connected" : "offline")")
    }
}
