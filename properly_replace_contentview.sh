#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
FILE="SmartTubecontroller/ContentView.swift"
if [ ! -f "$FILE" ]; then
  FILE="SmartTubecontroller/SmartTubecontroller/ContentView.swift"
fi
if [ ! -f "$FILE" ]; then
  echo "ContentView.swift not found from $ROOT"
  exit 1
fi

cp "$FILE" "$FILE.bak.$(date +%s)"

cat > "$FILE" <<'SWIFT'
//
//  ContentView.swift
//  SmartTubecontroller
//
//  Unified macOS player-style controller for SmartTube Remote API + ADB Bridge.
//  Requires SmartTubeSDK.swift and SmartTubeADBBridge.swift in the same Xcode target.
//

import SwiftUI
import Combine
import AppKit

struct RemoteFormat: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case video
        case audio
        case subtitle
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let selected: Bool
}

@MainActor
final class SmartTubeControllerViewModel: ObservableObject {
    @Published var host: String
    @Published var apiPort: String
    @Published var token: String
    @Published var bridgeHost: String
    @Published var bridgePort: String

    @Published var isAPIConnected: Bool = false
    @Published var isRealtimeConnected: Bool = false
    @Published var isBridgeConnected: Bool = false
    @Published var isBusy: Bool = false

    @Published var phase: String = "Ready"
    @Published var bridgePhase: String = "Bridge idle"
    @Published var lastError: String?

    @Published var player: PlayerState?
    @Published var queue: [QueueItem] = []
    @Published var theater: TheaterState?
    @Published var cec: SmartTubeCECState?
    @Published var videoFormats: [RemoteFormat] = []
    @Published var audioFormats: [RemoteFormat] = []
    @Published var subtitleFormats: [RemoteFormat] = []
    @Published var logs: [String] = []

    private var client: SmartTubeClient?
    private var bridge: SmartTubeADBBridgeClient?
    private var realtime: SmartTubeWebSocketClient?
    private var pollTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        self.host = defaults.string(forKey: "smarttube.host") ?? "127.0.0.1"
        self.apiPort = defaults.string(forKey: "smarttube.port") ?? "8497"
        self.token = defaults.string(forKey: "smarttube.token") ?? ""
        self.bridgeHost = defaults.string(forKey: "smarttube.bridge.host") ?? "127.0.0.1"
        self.bridgePort = defaults.string(forKey: "smarttube.bridge.port") ?? "8498"
    }

    var apiPortInt: Int { Int(self.apiPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8497 }
    var bridgePortInt: Int { Int(self.bridgePort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8498 }

    var title: String {
        if let value = self.player?.video?.title, !value.isEmpty { return value }
        return self.isAPIConnected ? "Connected — no video loaded" : "Not connected"
    }

    var subtitle: String {
        if let value = self.player?.video?.author, !value.isEmpty { return value }
        return "\(self.host):\(self.apiPortInt)"
    }

    var thumbnailURL: URL? {
        guard let raw = self.player?.video?.thumbnailURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var stateText: String { self.player?.state.rawValue.capitalized ?? "Idle" }
    var isPlaying: Bool { self.player?.state == .playing }
    var positionMs: Int { self.player?.positionMs ?? 0 }
    var durationMs: Int { self.player?.durationMs ?? self.player?.video?.durationMs ?? 0 }
    var playbackVolumePercent: Int { Int(((self.player?.volume ?? 0) * 100).rounded()) }

    var diagnostics: String {
        """
        SmartTube controller diagnostics
        API: \(self.host):\(self.apiPortInt)
        Bridge: \(self.bridgeHost):\(self.bridgePortInt)
        Token: \(self.redactedToken)
        Connected: api=\(self.isAPIConnected), realtime=\(self.isRealtimeConnected), bridge=\(self.isBridgeConnected)
        Phase: \(self.phase)
        Bridge phase: \(self.bridgePhase)
        Player: \(self.player?.state.rawValue ?? "nil") pos=\(self.positionMs) dur=\(self.durationMs)
        Video: \(self.player?.video?.title ?? "nil")
        Theater: volume=\(self.theater?.volume.description ?? "nil") muted=\(self.theater?.muted.description ?? "nil") output=\(self.theater?.audioOutput ?? "nil")
        CEC: output=\(self.cec?.audioOutput.rawValue ?? "nil") sub=\(self.cec?.subwooferLevel?.description ?? "nil") rear=\(self.cec?.rearLevel?.description ?? "nil") immersive=\(self.cec?.immersiveAEEnabled?.description ?? "nil") mode=\(self.cec?.soundMode?.rawValue ?? "nil")
        Last error: \(self.lastError ?? "nil")

        Log:
        \(self.logs.joined(separator: "\n"))
        """
    }

    var redactedToken: String {
        let value = self.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 10 else { return value.isEmpty ? "none" : value }
        return "\(value.prefix(6))…\(value.suffix(4))"
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        let line = "[\(formatter.string(from: Date()))] \(message)"
        self.logs.append(line)
        if self.logs.count > 500 {
            self.logs.removeFirst(self.logs.count - 500)
        }
    }

    func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self.logs.joined(separator: "\n"), forType: .string)
        self.log("Copied logs")
    }

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self.diagnostics, forType: .string)
        self.log("Copied diagnostics")
    }

    func saveSettings() {
        self.defaults.set(self.host, forKey: "smarttube.host")
        self.defaults.set(self.apiPort, forKey: "smarttube.port")
        self.defaults.set(self.token, forKey: "smarttube.token")
        self.defaults.set(self.bridgeHost, forKey: "smarttube.bridge.host")
        self.defaults.set(self.bridgePort, forKey: "smarttube.bridge.port")
    }

    func autoConnect() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }

        self.lastError = nil
        self.phase = "Connecting…"
        self.log("Starting auto connect")

        await self.connectBridgeIfPossible()
        if let bridge = self.bridge {
            do {
                let info = try await bridge.smartTubeAutoconnect()
                self.host = info.host
                self.apiPort = String(info.port)
                self.log("Forwarded SmartTube API from \(info.model) to \(info.host):\(info.port)")
            } catch {
                self.log("ADB forward skipped: \(error.localizedDescription)")
            }
        }

        await self.connectAPIAndPairIfNeeded()
    }

    func manualConnect() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        self.lastError = nil
        self.log("Manual connect")
        await self.connectAPIAndPairIfNeeded()
    }

    func connectBridgeIfPossible() async {
        self.bridgePhase = "Connecting bridge…"
        do {
            let b = try SmartTubeADBBridgeClient(host: self.bridgeHost, port: self.bridgePortInt)
            b.connect()
            _ = try await b.ping()
            self.bridge = b
            self.isBridgeConnected = true
            self.bridgePhase = "ADB bridge connected"
            self.log("ADB bridge connected at ws://\(self.bridgeHost):\(self.bridgePortInt)")
        } catch {
            self.bridge = nil
            self.isBridgeConnected = false
            self.bridgePhase = "Bridge unavailable"
            self.log("ADB bridge unavailable: \(error.localizedDescription)")
        }
    }

    func connectAPIAndPairIfNeeded() async {
        self.saveSettings()
        let plainClient = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt))

        do {
            let ping = try await plainClient.ping()
            self.phase = "Ping OK: \(ping.deviceName)"
            self.log("Ping OK: \(ping.deviceName)")
        } catch {
            self.isAPIConnected = false
            self.phase = "API connection failed"
            self.lastError = error.localizedDescription
            self.log("API connection failed: \(error.localizedDescription)")
            return
        }

        let savedToken = self.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedToken.isEmpty {
            let authed = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: savedToken))
            do {
                _ = try await authed.getPlayer()
                self.client = authed
                self.isAPIConnected = true
                self.phase = "Connected"
                self.log("Saved token accepted")
                await self.afterConnected()
                return
            } catch {
                self.log("Saved token rejected: \(error.localizedDescription)")
            }
        }

        do {
            self.phase = "Pairing automatically…"
            let pair = try await plainClient.getPairCode()
            let verified = try await self.verifyPairCodeRobust(client: plainClient, code: pair.code)
            self.token = verified.token
            self.client = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: verified.token))
            self.isAPIConnected = true
            self.phase = "Paired with \(verified.deviceName)"
            self.log("Auto pair OK")
            self.saveSettings()
            await self.afterConnected()
        } catch {
            self.isAPIConnected = false
            self.phase = "Pairing failed"
            self.lastError = "Pairing failed: \(error.localizedDescription)"
            self.log(self.lastError ?? "Pairing failed")
        }
    }

    private func verifyPairCodeRobust(client: SmartTubeClient, code: String) async throws -> PairVerifyResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isNumber }
        var candidates: [String] = []

        func add(_ value: String) {
            if !value.isEmpty && !candidates.contains(value) { candidates.append(value) }
        }

        add(trimmed)
        if digits.count == 6 {
            add(digits)
            add(String(digits.prefix(3)) + " " + String(digits.suffix(3)))
        }

        var lastError: Error?
        for candidate in candidates {
            do { return try await client.verifyPairCode(candidate) }
            catch { lastError = error }
        }
        throw lastError ?? SmartTubeError.emptyResponse
    }

    private func afterConnected() async {
        self.saveSettings()
        await self.refreshAll()
        self.connectRealtime()
        self.startPollingFallback()
    }

    func refreshAll() async {
        guard let c = self.client else { return }

        do {
            self.player = try await c.getPlayer()
            self.log("Player refreshed: \(self.player?.state.rawValue ?? "unknown")")
        } catch {
            self.log("Player refresh failed: \(error.localizedDescription)")
        }

        do {
            self.queue = try await c.getQueue()
            self.log("Queue refreshed: \(self.queue.count) items")
        } catch {
            self.log("Queue refresh failed: \(error.localizedDescription)")
        }

        do {
            self.theater = try await c.getTheater()
            self.log("Theater refreshed: volume \(self.theater?.volume ?? 0)")
        } catch {
            self.log("Theater refresh failed: \(error.localizedDescription)")
        }

        await self.refreshTracks()
        await self.refreshCEC()
    }

    func refreshFast() async {
        guard let c = self.client else { return }
        do { self.player = try await c.getPlayer() } catch { }
        do { self.queue = try await c.getQueue() } catch { }
        do { self.theater = try await c.getTheater() } catch { }
    }

    func refreshTracks() async {
        guard let c = self.client else { return }
        do {
            self.videoFormats = try await self.loadFormats(client: c, path: "/api/player/formats/video", kind: .video)
            self.audioFormats = try await self.loadFormats(client: c, path: "/api/player/formats/audio", kind: .audio)
            self.subtitleFormats = try await self.loadFormats(client: c, path: "/api/player/formats/subtitle", kind: .subtitle)
            self.log("Tracks refreshed")
        } catch {
            self.log("Tracks refresh failed: \(error.localizedDescription)")
        }
    }

    private func loadFormats(client: SmartTubeClient, path: String, kind: RemoteFormat.Kind) async throws -> [RemoteFormat] {
        let json = try await client.rawJSON(method: "GET", path: path)
        guard case .array(let rows) = json else { return [] }

        return rows.compactMap { value in
            guard case .object(let obj) = value else { return nil }
            guard let id = Self.string(obj["format_id"]), !id.isEmpty else { return nil }

            let label = Self.string(obj["label"])
            let codec = Self.string(obj["codec"])
            let language = Self.string(obj["language_label"]) ?? Self.string(obj["language"])
            let height = Self.int(obj["height"])
            let bitrate = Self.int(obj["bitrate"])
            let selected = Self.bool(obj["is_selected"]) ?? false

            let title: String
            switch kind {
            case .video:
                title = label ?? (height.map { "\($0)p" } ?? id)
            case .audio:
                title = language ?? label ?? codec ?? id
            case .subtitle:
                title = language ?? label ?? id
            }

            let bits = [codec, bitrate.map { "\($0 / 1000) kbps" }].compactMap { $0 }
            return RemoteFormat(id: id, kind: kind, title: title, subtitle: bits.joined(separator: " · "), selected: selected)
        }
    }

    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value else { return nil }
        return raw.isEmpty ? nil : raw
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard case .number(let raw) = value else { return nil }
        return Int(raw)
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let raw) = value else { return nil }
        return raw
    }

    func refreshCEC() async {
        guard let b = self.bridge else { return }
        do {
            let parsed = try await b.getParsedCECState()
            self.cec = Self.cleanCEC(parsed)
            self.log("CEC refreshed")
        } catch {
            self.log("CEC refresh failed: \(error.localizedDescription)")
        }
    }

    static func cleanCEC(_ state: SmartTubeCECState) -> SmartTubeCECState {
        var copy = state
        if copy.subwooferLevel == 255 { copy.subwooferLevel = nil }
        if copy.rearLevel == 255 { copy.rearLevel = nil }
        return copy
    }

    func connectRealtime() {
        self.realtime?.disconnect()
        guard !self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let socket = SmartTubeWebSocketClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: self.token))
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .hello(_, let deviceName):
                    self.isRealtimeConnected = true
                    self.log("Realtime connected\(deviceName.map { " to \($0)" } ?? "")")
                case .stateUpdate(let state):
                    self.player = state
                    self.isRealtimeConnected = true
                case .json(let json):
                    self.log("Realtime JSON: \(String(describing: json))")
                }
            }
        }
        socket.onError = { [weak self] error in
            Task { @MainActor in
                self?.isRealtimeConnected = false
                self?.log("Realtime warning: \(error.localizedDescription)")
            }
        }
        socket.onClose = { [weak self] in
            Task { @MainActor in
                self?.isRealtimeConnected = false
                self?.log("Realtime closed; polling continues")
            }
        }

        do {
            try socket.connect()
            self.realtime = socket
            self.isRealtimeConnected = true
            self.log("Realtime connecting")
        } catch {
            self.isRealtimeConnected = false
            self.log("Realtime unavailable: \(error.localizedDescription)")
        }
    }

    func startPollingFallback() {
        self.pollTask?.cancel()
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshFast()
            }
        }
    }

    func run(_ label: String, _ operation: @MainActor @escaping () async throws -> Void) async {
        guard !self.isBusy else { return }
        self.isBusy = true
        self.phase = label
        self.log(label)
        defer { self.isBusy = false }
        do {
            try await operation()
            self.phase = "\(label) OK"
            self.log("\(label) OK")
            await self.refreshFast()
        } catch {
            self.lastError = "\(label) failed: \(error.localizedDescription)"
            self.phase = self.lastError ?? "Failed"
            self.log("Failed: \(self.lastError ?? error.localizedDescription)")
        }
    }

    func togglePlay() async {
        await self.run("Play/Pause") {
            try await self.clientOrThrow().toggle()
        }
    }

    func play() async {
        await self.run("Play") {
            try await self.clientOrThrow().play()
        }
    }

    func pause() async {
        await self.run("Pause") {
            try await self.clientOrThrow().pause()
        }
    }

    func next() async {
        await self.run("Next") {
            try await self.clientOrThrow().next()
        }
    }

    func previous() async {
        await self.run("Previous") {
            try await self.clientOrThrow().previous()
        }
    }

    func seek(ms: Int) async {
        await self.run("Seek") {
            try await self.clientOrThrow().seek(positionMs: max(ms, 0))
        }
    }

    func seekBy(seconds: Int) async {
        await self.seek(ms: max(self.positionMs + seconds * 1000, 0))
    }

    func setPlaybackVolume(percent: Int) async {
        let value = min(max(Double(percent) / 100.0, 0), 1)
        await self.run("Set playback volume") {
            try await self.clientOrThrow().setVolume(value)
        }
    }

    func tvVolumeUp() async {
        await self.run("TV volume up") {
            try await self.clientOrThrow().theaterVolumeUp()
        }
    }

    func tvVolumeDown() async {
        await self.run("TV volume down") {
            try await self.clientOrThrow().theaterVolumeDown()
        }
    }

    func toggleTVMute() async {
        await self.run("Toggle TV mute") {
            try await self.clientOrThrow().toggleTheaterMute()
        }
    }

    func openVideo(_ input: String) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await self.run("Open video") {
            if text.contains("/") || text.contains("youtube.com") || text.contains("youtu.be") {
                try await self.clientOrThrow().openURL(text)
            } else {
                try await self.clientOrThrow().openVideoId(text)
            }
        }
    }

    func searchAndPlay(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await self.run("Search and play") {
            try await self.clientOrThrow().searchAndPlay(text)
        }
    }

    func addToQueue(_ input: String) async {
        let id = Self.extractVideoId(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !id.isEmpty else { return }
        await self.run("Add to queue") {
            try await self.clientOrThrow().addToQueue(videoId: id)
        }
    }

    func playNext(_ input: String) async {
        let id = Self.extractVideoId(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !id.isEmpty else { return }
        await self.run("Play next") {
            try await self.clientOrThrow().playNext(videoId: id)
        }
    }

    func removeQueueItem(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await self.run("Remove queue item") {
            try await self.clientOrThrow().removeFromQueue(videoId: id)
        }
    }

    func clearQueue() async {
        await self.run("Clear queue") {
            try await self.clientOrThrow().clearQueue()
        }
    }

    func setVideoFormat(_ id: String) async {
        await self.run("Set video format") {
            try await self.clientOrThrow().setVideoFormat(id)
        }
        await self.refreshTracks()
    }

    func setAudioFormat(_ id: String) async {
        await self.run("Set audio format") {
            try await self.clientOrThrow().setAudioFormat(id)
        }
        await self.refreshTracks()
    }

    func setSubtitleFormat(_ id: String?) async {
        await self.run("Set subtitles") {
            try await self.clientOrThrow().setSubtitleFormat(id)
        }
        await self.refreshTracks()
    }

    func setHomeTheater() async {
        await self.run("Set home theater speakers") {
            _ = try await self.bridgeOrThrow().setHomeTheaterSpeakers()
        }
        await self.refreshCEC()
    }

    func setTVSpeakers() async {
        await self.run("Set TV speakers") {
            _ = try await self.bridgeOrThrow().setTVSpeakers()
        }
        await self.refreshCEC()
    }

    func setSubwoofer(_ level: Double) async {
        await self.run("Set subwoofer") {
            try await self.bridgeOrThrow().setSubwooferLevel(Int(level.rounded()))
        }
        await self.refreshCEC()
    }

    func setRear(_ level: Double) async {
        await self.run("Set rear level") {
            try await self.bridgeOrThrow().setRearLevel(Int(level.rounded()))
        }
        await self.refreshCEC()
    }

    func setImmersive(_ enabled: Bool) async {
        await self.run("Set Immersive AE") {
            try await self.bridgeOrThrow().setImmersiveAE(enabled)
        }
        await self.refreshCEC()
    }

    func setSoundMode(_ mode: SmartTubeSoundMode) async {
        await self.run("Set sound mode") {
            try await self.bridgeOrThrow().setSoundMode(mode)
        }
        await self.refreshCEC()
    }

    func powerToggle() async {
        await self.run("Power toggle") {
            if let bridge = self.bridge {
                try await bridge.powerToggle()
            } else {
                try await self.clientOrThrow().toggleTheaterPower()
            }
        }
    }

    private func clientOrThrow() throws -> SmartTubeClient {
        guard let client = self.client else { throw SmartTubeError.missingToken }
        return client
    }

    private func bridgeOrThrow() throws -> SmartTubeADBBridgeClient {
        guard let bridge = self.bridge else { throw SmartTubeADBBridgeError.notConnected }
        return bridge
    }

    static func extractVideoId(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        if let url = URL(string: input), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
            if url.host?.contains("youtu.be") == true {
                return url.pathComponents.dropFirst().first ?? input
            }
        }
        return input
    }

    static func formatTime(_ ms: Int) -> String {
        let total = max(ms / 1000, 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

struct ContentView: View {
    @StateObject private var vm = SmartTubeControllerViewModel()
    @State private var videoText: String = ""
    @State private var searchText: String = ""
    @State private var seekValue: Double = 0
    @State private var isDraggingSeek: Bool = false
    @State private var subwooferLevel: Double = 8
    @State private var rearLevel: Double = 8
    @State private var immersiveAE: Bool = false
    @State private var soundMode: SmartTubeSoundMode = .cinema

    var body: some View {
        VStack(spacing: 0) {
            self.toolbarView
            Divider()
            HStack(spacing: 0) {
                self.playerColumn
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                self.sideColumn
                    .frame(width: 390)
            }
        }
        .frame(minWidth: 1060, minHeight: 720)
        .background(.regularMaterial)
        .task {
            await self.vm.autoConnect()
        }
        .onChange(of: self.vm.positionMs) { _, newValue in
            if !self.isDraggingSeek {
                self.seekValue = Double(newValue)
            }
        }
        .onChange(of: self.vm.cec) { _, newValue in
            if let sub = newValue?.subwooferLevel { self.subwooferLevel = Double(sub) }
            if let rear = newValue?.rearLevel { self.rearLevel = Double(rear) }
            if let immersive = newValue?.immersiveAEEnabled { self.immersiveAE = immersive }
            if let mode = newValue?.soundMode { self.soundMode = mode }
        }
    }

    private var toolbarView: some View {
        HStack(spacing: 12) {
            connectionBadge(title: "API", active: self.vm.isAPIConnected)
            connectionBadge(title: "Live", active: self.vm.isRealtimeConnected)
            connectionBadge(title: "ADB", active: self.vm.isBridgeConnected)

            Divider().frame(height: 24)

            TextField("API host", text: self.$vm.host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            TextField("Port", text: self.$vm.apiPort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)

            Button("Connect") {
                Task { await self.vm.manualConnect() }
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Auto") {
                Task { await self.vm.autoConnect() }
            }

            Spacer()

            if self.vm.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(self.vm.phase)
                .font(.caption)
                .foregroundStyle(self.vm.lastError == nil ? .secondary : .red)
                .lineLimit(1)
                .frame(maxWidth: 320, alignment: .trailing)

            Button("Copy Logs") { self.vm.copyLogs() }
            Button("Diagnostics") { self.vm.copyDiagnostics() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var playerColumn: some View {
        VStack(spacing: 18) {
            self.heroView
            self.transportView
            self.addVideoView
            self.statusStrip
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var heroView: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.gradient)

            if let url = self.vm.thumbnailURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .overlay(.black.opacity(0.28))
                    case .failure:
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(.white.opacity(0.35))
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(self.vm.stateText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                Text(self.vm.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(2)
                Text(self.vm.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(radius: 10)
            .padding(24)
        }
        .frame(minHeight: 300, maxHeight: 390)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var transportView: some View {
        VStack(spacing: 14) {
            Slider(
                value: self.$seekValue,
                in: 0...Double(max(self.vm.durationMs, 1)),
                onEditingChanged: { editing in
                    self.isDraggingSeek = editing
                    if !editing {
                        Task { await self.vm.seek(ms: Int(self.seekValue)) }
                    }
                }
            )
            HStack {
                Text(SmartTubeControllerViewModel.formatTime(Int(self.seekValue)))
                Spacer()
                Text(SmartTubeControllerViewModel.formatTime(self.vm.durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                transportButton("backward.end.fill", title: "Previous") {
                    Task { await self.vm.previous() }
                }
                transportButton("gobackward.10", title: "Back 10") {
                    Task { await self.vm.seekBy(seconds: -10) }
                }
                Button {
                    Task { await self.vm.togglePlay() }
                } label: {
                    Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .frame(width: 74, height: 54)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                transportButton("goforward.10", title: "Forward 10") {
                    Task { await self.vm.seekBy(seconds: 10) }
                }
                transportButton("forward.end.fill", title: "Next") {
                    Task { await self.vm.next() }
                }

                Divider().frame(height: 34)

                Button {
                    Task { await self.vm.tvVolumeDown() }
                } label: {
                    Image(systemName: "speaker.minus.fill")
                }
                Button {
                    Task { await self.vm.toggleTVMute() }
                } label: {
                    Image(systemName: self.vm.theater?.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Button {
                    Task { await self.vm.tvVolumeUp() }
                } label: {
                    Image(systemName: "speaker.plus.fill")
                }
                Text("TV \(self.vm.theater?.volume ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var addVideoView: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Paste YouTube URL or video id", text: self.$videoText)
                    .textFieldStyle(.roundedBorder)
                Button("Play Now") {
                    let value = self.videoText
                    self.videoText = ""
                    Task { await self.vm.openVideo(value) }
                }
                Button("Queue") {
                    let value = self.videoText
                    self.videoText = ""
                    Task { await self.vm.addToQueue(value) }
                }
                Button("Play Next") {
                    let value = self.videoText
                    self.videoText = ""
                    Task { await self.vm.playNext(value) }
                }
            }
            HStack {
                TextField("Search YouTube and play first result", text: self.$searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Search + Play") {
                    let value = self.searchText
                    self.searchText = ""
                    Task { await self.vm.searchAndPlay(value) }
                }
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 14) {
            Label("Playback \(self.vm.playbackVolumePercent)%", systemImage: "waveform")
            Label("Queue \(self.vm.queue.count)", systemImage: "list.bullet")
            Label(self.vm.theater?.audioOutput ?? "Audio output unknown", systemImage: "hifispeaker.2")
            if let error = self.vm.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var sideColumn: some View {
        VStack(spacing: 0) {
            self.queuePanel
            Divider()
            self.inspectorPanel
        }
        .background(.ultraThinMaterial)
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Up Next")
                    .font(.headline)
                Spacer()
                Button("Refresh") { Task { await self.vm.refreshFast() } }
                Button("Clear") { Task { await self.vm.clearQueue() } }
            }
            List {
                ForEach(self.vm.queue) { item in
                    HStack(spacing: 10) {
                        Text("\((item.index ?? 0) + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title ?? item.videoId ?? "Untitled")
                                .lineLimit(1)
                            Text(item.author ?? item.videoId ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if item.isCurrent == true {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.green)
                        }
                        Button {
                            Task { await self.vm.removeQueueItem(item) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
        }
        .padding(14)
        .frame(maxHeight: .infinity)
    }

    private var inspectorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.trackPicker(title: "Quality", formats: self.vm.videoFormats) { id in
                    Task { await self.vm.setVideoFormat(id) }
                }
                self.trackPicker(title: "Audio", formats: self.vm.audioFormats) { id in
                    Task { await self.vm.setAudioFormat(id) }
                }
                self.trackPicker(title: "Subtitles", formats: self.vm.subtitleFormats) { id in
                    Task { await self.vm.setSubtitleFormat(id) }
                }
                Button("Disable Subtitles") {
                    Task { await self.vm.setSubtitleFormat(nil) }
                }

                Divider()

                Text("Theater")
                    .font(.headline)
                HStack {
                    Button("Home Theater") { Task { await self.vm.setHomeTheater() } }
                    Button("TV Speakers") { Task { await self.vm.setTVSpeakers() } }
                }
                HStack {
                    Text("Sub")
                    Slider(
                        value: self.$subwooferLevel,
                        in: 0...12,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing { Task { await self.vm.setSubwoofer(self.subwooferLevel) } }
                        }
                    )
                    Text("\(Int(self.subwooferLevel))")
                        .monospacedDigit()
                }
                HStack {
                    Text("Rear")
                    Slider(
                        value: self.$rearLevel,
                        in: 0...12,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing { Task { await self.vm.setRear(self.rearLevel) } }
                        }
                    )
                    Text("\(Int(self.rearLevel))")
                        .monospacedDigit()
                }
                Toggle("Immersive AE", isOn: Binding(
                    get: { self.immersiveAE },
                    set: { value in
                        self.immersiveAE = value
                        Task { await self.vm.setImmersive(value) }
                    }
                ))
                Picker("Sound Mode", selection: self.$soundMode) {
                    ForEach(SmartTubeSoundMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .onChange(of: self.soundMode) { _, newValue in
                    Task { await self.vm.setSoundMode(newValue) }
                }

                Divider()

                Text("Bridge")
                    .font(.headline)
                HStack {
                    TextField("Bridge host", text: self.$vm.bridgeHost)
                    TextField("Port", text: self.$vm.bridgePort)
                        .frame(width: 70)
                }
                .textFieldStyle(.roundedBorder)
                Button("Reconnect Bridge") {
                    Task { await self.vm.connectBridgeIfPossible() }
                }
                Button("Power Toggle") {
                    Task { await self.vm.powerToggle() }
                }
                Text(self.vm.bridgePhase)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Logs")
                    .font(.headline)
                Text(self.vm.logs.suffix(12).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(height: 360)
    }

    private func trackPicker(title: String, formats: [RemoteFormat], action: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if formats.isEmpty {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(formats.prefix(8)) { format in
                Button {
                    action(format.id)
                } label: {
                    HStack {
                        Image(systemName: format.selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(format.selected ? Color.green : Color.secondary)
                        VStack(alignment: .leading) {
                            Text(format.title)
                                .lineLimit(1)
                            if !format.subtitle.isEmpty {
                                Text(format.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func transportButton(_ systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 34)
        }
        .help(title)
    }

    private func connectionBadge(title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? .green : .secondary.opacity(0.45))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

#Preview {
    ContentView()
}
SWIFT

echo "Replaced $FILE with clean unified player UI."
echo "Now run: Product → Clean Build Folder → Run"
