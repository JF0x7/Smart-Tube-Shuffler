#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT"

CONTENT_VIEW=""
for p in \
  "SmartTubecontroller/ContentView.swift" \
  "SmartTubecontroller/SmartTubecontroller/ContentView.swift" \
  "ContentView.swift"
do
  if [[ -f "$p" ]]; then
    CONTENT_VIEW="$p"
    break
  fi
done

if [[ -z "$CONTENT_VIEW" ]]; then
  CONTENT_VIEW="$(find . -name ContentView.swift -print -quit | sed 's#^./##')"
fi

if [[ -z "$CONTENT_VIEW" ]]; then
  echo "ContentView.swift not found. Run this from the Xcode project root."
  exit 1
fi

cp "$CONTENT_VIEW" "$CONTENT_VIEW.bak.$(date +%Y%m%d%H%M%S)"

cat > "$CONTENT_VIEW" <<'SWIFT'
//
//  ContentView.swift
//  SmartTubecontroller
//
//  macOS SwiftUI controller for SmartTube Remote API + local ADB bridge.
//  Requires SmartTubeSDK.swift and SmartTubeADBBridge.swift in the same target.
//

import SwiftUI
import Combine
import AppKit

// MARK: - View Model

@MainActor
final class SmartTubeControllerViewModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case remote = "Remote"
        case queue = "Queue"
        case tracks = "Tracks"
        case theater = "Theater"
        case settings = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .remote: return "play.rectangle.fill"
            case .queue: return "list.bullet.rectangle"
            case .tracks: return "slider.horizontal.3"
            case .theater: return "hifispeaker.2.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    enum ConnectionPhase: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        case needsPairing(String)
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Ready"
            case .connecting(let value): return value
            case .connected(let value): return value
            case .needsPairing(let value): return value
            case .failed(let value): return value
            }
        }

        var isWorking: Bool {
            if case .connecting = self { return true }
            return false
        }

        var systemImage: String {
            switch self {
            case .idle: return "circle"
            case .connecting: return "arrow.triangle.2.circlepath"
            case .connected: return "checkmark.circle.fill"
            case .needsPairing: return "key.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published var selectedSection: Section = .remote

    @Published var host: String
    @Published var apiPort: String
    @Published var token: String
    @Published var pairCodeInput: String = ""
    @Published var pairCodeFromTV: String = ""

    @Published var bridgeHost: String
    @Published var bridgePort: String
    @Published var adbTVHost: String
    @Published var subnetPrefix: String

    @Published var videoInput: String = ""
    @Published var searchInput: String = ""
    @Published var queueInput: String = ""

    @Published var phase: ConnectionPhase = .idle
    @Published var bridgePhase: ConnectionPhase = .idle
    @Published var isConnected: Bool = false
    @Published var isRealtimeConnected: Bool = false
    @Published var isBridgeConnected: Bool = false
    @Published var isBusy: Bool = false
    @Published var lastError: String?
    @Published var connectionLog: [String] = []

    @Published var playerState: PlayerState?
    @Published var queue: [QueueItem] = []
    @Published var videoFormats: [VideoFormat] = []
    @Published var audioFormats: [AudioFormat] = []
    @Published var subtitleFormats: [SubtitleFormat] = []
    @Published var theaterState: TheaterState?
    @Published var cecState: SmartTubeCECState?

    private var client: SmartTubeClient?
    private var socket: SmartTubeWebSocketClient?
    private var bridge: SmartTubeADBBridgeClient?
    private let defaults = UserDefaults.standard

    init() {
        self.host = defaults.string(forKey: "smarttube.host") ?? "127.0.0.1"
        self.apiPort = defaults.string(forKey: "smarttube.port") ?? "8497"
        self.token = defaults.string(forKey: "smarttube.token") ?? ""
        self.bridgeHost = defaults.string(forKey: "smarttube.bridge.host") ?? "127.0.0.1"
        self.bridgePort = defaults.string(forKey: "smarttube.bridge.port") ?? "8498"
        self.adbTVHost = defaults.string(forKey: "smarttube.adb.tvhost") ?? ""
        self.subnetPrefix = defaults.string(forKey: "smarttube.subnet.prefix") ?? "192.168.1"
    }

    var currentPort: Int { Int(apiPort.trimmed) ?? 8497 }
    var currentBridgePort: Int { Int(bridgePort.trimmed) ?? 8498 }

    var deviceTitle: String {
        if let title = playerState?.video?.title, !title.isEmpty { return title }
        return isConnected ? "Connected — no video loaded" : "Not connected"
    }

    var deviceSubtitle: String {
        if let author = playerState?.video?.author, !author.isEmpty { return author }
        return host.isEmpty ? "SmartTube" : "\(host):\(apiPort)"
    }

    var thumbnailURL: URL? {
        guard let raw = playerState?.video?.thumbnailURL else { return nil }
        return URL(string: raw)
    }

    var playbackStateText: String { playerState?.state.rawValue.capitalized ?? "Idle" }

    var positionMs: Int { playerState?.positionMs ?? 0 }
    var durationMs: Int { playerState?.durationMs ?? playerState?.video?.durationMs ?? 0 }

    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }

    var timeText: String {
        "\(Self.formatTime(positionMs)) / \(Self.formatTime(durationMs))"
    }

    var volumePercent: Int {
        Int(((playerState?.volume ?? 0) * 100).rounded())
    }

    func bootstrap() {
        Task { await autoDiscoverConnectAndPair() }
    }

    func autoDiscoverConnectAndPair() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        connectionLog.removeAll()
        defer { isBusy = false }

        log("Starting automatic connection")

        if await tryBridgeForwarding() {
            if await connectOrAutoPair(host: host, port: currentPort, source: "ADB bridge") {
                return
            }
        }

        if await trySavedDirectConnection() {
            return
        }

        if await tryUDPDiscovery() {
            return
        }

        if await trySubnetScan() {
            return
        }

        fail("Could not find SmartTube. Start the Node ADB bridge or enter the TV IP manually.")
    }

    private func tryBridgeForwarding() async -> Bool {
        let bridgeHostValue = bridgeHost.trimmed.nilIfEmpty ?? "127.0.0.1"
        let bridgePortValue = currentBridgePort
        bridgePhase = .connecting("Checking ADB bridge…")
        log("Checking ADB bridge at ws://\(bridgeHostValue):\(bridgePortValue)")

        do {
            let newBridge = try SmartTubeADBBridgeClient(host: bridgeHostValue, port: bridgePortValue)
            newBridge.connect()
            _ = try await newBridge.ping()
            bridge = newBridge
            isBridgeConnected = true
            bridgePhase = .connected("ADB bridge connected")
            log("ADB bridge connected")

            if let tvHost = adbTVHost.trimmed.nilIfEmpty {
                do {
                    _ = try await newBridge.connectADBDevice(tvHost)
                    log("ADB connected to \(tvHost):5555")
                } catch {
                    log("ADB connect skipped/failed: \(error.localizedDescription)")
                }
            }

            let info = try await newBridge.smartTubeAutoconnect()
            host = info.host
            apiPort = String(info.port)
            saveConnectionFields()
            log("Forwarded SmartTube API from \(info.model.isEmpty ? info.serial : info.model) to \(info.host):\(info.port)")
            return true
        } catch {
            isBridgeConnected = false
            bridgePhase = .failed("ADB bridge unavailable")
            log("ADB bridge failed: \(error.localizedDescription)")
            return false
        }
    }

    private func trySavedDirectConnection() async -> Bool {
        let savedHost = host.trimmed
        guard !savedHost.isEmpty else { return false }
        log("Trying saved SmartTube address \(savedHost):\(currentPort)")
        return await connectOrAutoPair(host: savedHost, port: currentPort, source: "saved address")
    }

    private func tryUDPDiscovery() async -> Bool {
        phase = .connecting("Discovering SmartTube TVs…")
        log("Trying UDP discovery")

        do {
            let devices = try await SmartTubeDiscovery.discoverUDP(port: currentPort, timeout: 2.0)
            for device in devices {
                guard let discoveredHost = device.host else { continue }
                log("Discovered \(device.deviceName) at \(discoveredHost):\(device.apiPort)")
                if await connectOrAutoPair(host: discoveredHost, port: device.apiPort, source: device.deviceName) {
                    return true
                }
            }
        } catch {
            log("UDP discovery failed: \(error.localizedDescription)")
        }

        return false
    }

    private func trySubnetScan() async -> Bool {
        let prefix = subnetPrefix.trimmed
        guard !prefix.isEmpty else { return false }

        phase = .connecting("Scanning \(prefix).x…")
        log("Scanning subnet \(prefix).1-254")
        let results = await SmartTubeDiscovery.scanSubnet(prefix: prefix, port: currentPort, timeout: 0.45, maxConcurrent: 48)

        for item in results {
            log("Found SmartTube at \(item.host):\(currentPort)")
            if await connectOrAutoPair(host: item.host, port: currentPort, source: "subnet scan") {
                return true
            }
        }

        log("Subnet scan found no usable device")
        return false
    }

    @discardableResult
    private func connectOrAutoPair(host targetHost: String, port targetPort: Int, source: String) async -> Bool {
        phase = .connecting("Connecting via \(source)…")
        self.host = targetHost
        self.apiPort = String(targetPort)
        saveConnectionFields()

        let baseClient = SmartTubeClient(config: SmartTubeConfig(host: targetHost, port: targetPort, token: token.trimmed.nilIfEmpty))

        do {
            let ping = try await baseClient.ping()
            log("Ping OK: \(ping.deviceName)")

            if let savedToken = token.trimmed.nilIfEmpty {
                do {
                    let authed = SmartTubeClient(config: SmartTubeConfig(host: targetHost, port: targetPort, token: savedToken))
                    client = authed
                    _ = try await authed.getPlayer()
                    isConnected = true
                    phase = .connected("Connected to \(ping.deviceName)")
                    log("Saved token accepted")
                    await afterConnected()
                    return true
                } catch {
                    log("Saved token rejected, trying auto-pair: \(error.localizedDescription)")
                    token = ""
                    defaults.removeObject(forKey: "smarttube.token")
                }
            }

            do {
                let pair = try await baseClient.getPairCode()
                pairCodeFromTV = pair.code
                phase = .connecting("Pairing with \(ping.deviceName)…")
                log("Got pair code \(pairCodeFromTV)")
                let verified = try await verifyPairCode(baseClient, code: pairCodeFromTV)
                token = verified.token
                defaults.set(verified.token, forKey: "smarttube.token")
                client = baseClient
                isConnected = true
                phase = .connected("Paired with \(verified.deviceName)")
                log("Auto-pair OK")
                await afterConnected()
                return true
            } catch {
                phase = .needsPairing("Manual pairing needed")
                lastError = "Auto-pair failed: \(error.localizedDescription). Enter the 6-digit code and press Pair."
                log(lastError ?? "Auto-pair failed")
                return false
            }
        } catch {
            log("Connect failed for \(targetHost):\(targetPort): \(error.localizedDescription)")
            return false
        }
    }


    private func verifyPairCode(_ client: SmartTubeClient, code: String) async throws -> PairVerifyResponse {
        let trimmed = code.trimmed
        let digits = trimmed.filter { $0.isNumber }
        var candidates: [String] = []

        func add(_ value: String) {
            let value = value.trimmed
            if !value.isEmpty && !candidates.contains(value) {
                candidates.append(value)
            }
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
        saveConnectionFields()
        do { try await refreshAll() } catch { log("Initial refresh failed: \(error.localizedDescription)") }
        connectRealtime()
    }

    func manualConnect() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        if !token.trimmed.isEmpty {
            _ = await connectOrAutoPair(host: host.trimmed, port: currentPort, source: "manual")
        } else {
            await getPairCode()
        }
    }

    func getPairCode() async {
        phase = .connecting("Getting pair code…")
        do {
            let c = SmartTubeClient(config: SmartTubeConfig(host: host.trimmed, port: currentPort))
            let response = try await c.getPairCode()
            pairCodeFromTV = response.code
            client = c
            phase = .needsPairing("Enter pairing code")
            log("Pair code requested. Expires in \(response.expiresIn)s")
        } catch {
            fail("Could not get pair code: \(error.localizedDescription)")
        }
    }

    func manualPair() async {
        let input = pairCodeInput.trimmed.nilIfEmpty ?? pairCodeFromTV.trimmed
        guard !input.isEmpty else {
            fail("Enter the 6-digit pairing code first.")
            return
        }

        phase = .connecting("Pairing…")
        do {
            let c = SmartTubeClient(config: SmartTubeConfig(host: host.trimmed, port: currentPort))
            let verified = try await verifyPairCode(c, code: input)
            token = verified.token
            defaults.set(verified.token, forKey: "smarttube.token")
            client = c
            isConnected = true
            phase = .connected("Paired with \(verified.deviceName)")
            log("Manual pair OK")
            await afterConnected()
        } catch {
            fail("Invalid pairing code or expired code: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        client = nil
        isConnected = false
        isRealtimeConnected = false
        phase = .idle
        log("Disconnected")
    }

    func forgetToken() {
        token = ""
        defaults.removeObject(forKey: "smarttube.token")
        disconnect()
        phase = .needsPairing("Token removed. Pair again.")
    }

    func connectRealtime() {
        socket?.disconnect()
        guard let auth = token.trimmed.nilIfEmpty else {
            isRealtimeConnected = false
            log("Realtime skipped: no token")
            return
        }

        let ws = SmartTubeWebSocketClient(config: SmartTubeConfig(host: host.trimmed, port: currentPort, token: auth))
        ws.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .hello(_, let deviceName):
                    self.isRealtimeConnected = true
                    self.log("Realtime connected\(deviceName.map { " to \($0)" } ?? "")")
                case .stateUpdate(let state):
                    self.playerState = state
                    self.isRealtimeConnected = true
                case .json:
                    break
                }
            }
        }
        ws.onError = { [weak self] error in
            Task { @MainActor in
                self?.isRealtimeConnected = false
                self?.lastError = "Realtime error: \(error.localizedDescription)"
            }
        }
        ws.onClose = { [weak self] in
            Task { @MainActor in self?.isRealtimeConnected = false }
        }

        do {
            try ws.connect()
            socket = ws
            isRealtimeConnected = true
        } catch {
            isRealtimeConnected = false
            lastError = "Realtime connect failed: \(error.localizedDescription)"
        }
    }

    func refreshAll() async throws {
        let c = try requireClient()
        async let state = c.getPlayer()
        async let q = c.getQueue()
        async let theater = c.getTheater()
        playerState = try await state
        queue = (try? await q) ?? []
        theaterState = try? await theater
    }

    func refreshTracks() async {
        do {
            let c = try requireClient()
            async let vf = c.getVideoFormats()
            async let af = c.getAudioFormats()
            async let sf = c.getSubtitleFormats()
            videoFormats = (try? await vf) ?? []
            audioFormats = (try? await af) ?? []
            subtitleFormats = (try? await sf) ?? []
        } catch { fail(error.localizedDescription) }
    }

    func refreshCEC() async {
        do {
            let b = try requireBridge()
            cecState = try await b.getParsedCECState()
        } catch { fail("CEC refresh failed: \(error.localizedDescription)") }
    }

    func playPause() { sendSocketOrTask { try await $0.toggle() } socketCommand: { try $0.toggle() } }
    func play() { sendSocketOrTask { try await $0.play() } socketCommand: { try $0.play() } }
    func pause() { sendSocketOrTask { try await $0.pause() } socketCommand: { try $0.pause() } }
    func previous() { sendSocketOrTask { try await $0.previous() } socketCommand: { try $0.previous() } }
    func next() { sendSocketOrTask { try await $0.next() } socketCommand: { try $0.next() } }
    func stop() { sendSocketOrTask { try await $0.stop() } socketCommand: { try $0.stop() } }

    func seekRelative(_ deltaMs: Int) {
        let newPosition = max(0, min(durationMs, positionMs + deltaMs))
        seek(toProgress: durationMs > 0 ? Double(newPosition) / Double(durationMs) : 0)
    }

    func seek(toProgress value: Double) {
        guard durationMs > 0 else { return }
        let position = Int(Double(durationMs) * min(max(value, 0), 1))
        sendSocketOrTask { try await $0.seek(positionMs: position) } socketCommand: { try $0.seek(positionMs: position) }
    }

    func setPlaybackVolume(_ percent: Double) {
        let volume = min(max(percent / 100, 0), 1)
        sendSocketOrTask { try await $0.setVolume(volume) } socketCommand: { try $0.setVolume(volume) }
    }

    func setSpeed(_ speed: Double) {
        sendSocketOrTask { try await $0.setSpeed(speed) } socketCommand: { try $0.setSpeed(speed) }
    }

    func openVideo() async {
        let input = videoInput.trimmed
        guard !input.isEmpty else { return }
        await runAction("Opening video…") {
            let c = try requireClient()
            if input.contains("/") {
                _ = try await c.openURL(input)
            } else {
                _ = try await c.openVideoId(input)
            }
            videoInput = ""
            try await refreshAll()
        }
    }

    func searchAndPlay() async {
        let query = searchInput.trimmed
        guard !query.isEmpty else { return }
        await runAction("Searching…") {
            let c = try requireClient()
            _ = try await c.searchAndPlay(query)
            try await refreshAll()
        }
    }

    func addQueue() async {
        let id = queueInput.trimmed
        guard !id.isEmpty else { return }
        await runAction("Adding to queue…") {
            let c = try requireClient()
            _ = try await c.addToQueue(videoId: id)
            queueInput = ""
            queue = try await c.getQueue()
        }
    }

    func playNextQueue() async {
        let id = queueInput.trimmed
        guard !id.isEmpty else { return }
        await runAction("Adding next…") {
            let c = try requireClient()
            _ = try await c.playNext(videoId: id)
            queueInput = ""
            queue = try await c.getQueue()
        }
    }

    func clearQueue() async {
        await runAction("Clearing queue…") {
            let c = try requireClient()
            _ = try await c.clearQueue()
            queue = []
        }
    }

    func selectVideoFormat(_ id: String) async {
        await runAction("Switching video format…") {
            _ = try await requireClient().setVideoFormat(id)
            await refreshTracks()
        }
    }

    func selectAudioFormat(_ id: String) async {
        await runAction("Switching audio format…") {
            _ = try await requireClient().setAudioFormat(id)
            await refreshTracks()
        }
    }

    func selectSubtitleFormat(_ id: String?) async {
        await runAction("Switching subtitles…") {
            _ = try await requireClient().setSubtitleFormat(id)
            await refreshTracks()
        }
    }

    func setTheaterVolume(_ value: Double) async {
        await runAction("Setting TV volume…") {
            let c = try requireClient()
            _ = try await c.setTheaterVolume(Int(value.rounded()))
            theaterState = try? await c.getTheater()
        }
    }

    func theaterVolumeStep(up: Bool) async {
        await runAction(up ? "Volume up…" : "Volume down…") {
            let c = try requireClient()
            if up { _ = try await c.theaterVolumeUp() } else { _ = try await c.theaterVolumeDown() }
            theaterState = try? await c.getTheater()
        }
    }

    func toggleTheaterMute() async {
        await runAction("Toggling TV mute…") {
            let c = try requireClient()
            _ = try await c.toggleTheaterMute()
            theaterState = try? await c.getTheater()
        }
    }

    func powerToggle() async {
        if let b = bridge {
            await runAction("Power toggle…") { _ = try await b.powerToggle() }
        } else {
            await runAction("Power toggle…") { _ = try await requireClient().toggleTheaterPower() }
        }
    }

    func setOutputTheater() async {
        await runAction("Switching to theater speakers…") {
            _ = try await requireBridge().setHomeTheaterSpeakers()
            await refreshCEC()
        }
    }

    func setOutputTV() async {
        await runAction("Switching to TV speakers…") {
            _ = try await requireBridge().setTVSpeakers()
            await refreshCEC()
        }
    }

    func setSubwoofer(_ level: Double) async {
        await runAction("Setting subwoofer…") {
            _ = try await requireBridge().setSubwooferLevel(Int(level.rounded()))
            await refreshCEC()
        }
    }

    func setRear(_ level: Double) async {
        await runAction("Setting rear level…") {
            _ = try await requireBridge().setRearLevel(Int(level.rounded()))
            await refreshCEC()
        }
    }

    func setImmersive(_ enabled: Bool) async {
        await runAction("Setting immersive AE…") {
            _ = try await requireBridge().setImmersiveAE(enabled)
            await refreshCEC()
        }
    }

    func setSoundMode(_ mode: SmartTubeSoundMode) async {
        await runAction("Setting sound mode…") {
            _ = try await requireBridge().setSoundMode(mode)
            await refreshCEC()
        }
    }

    private func sendSocketOrTask(_ rest: @escaping (SmartTubeClient) async throws -> Void, socketCommand: @escaping (SmartTubeWebSocketClient) throws -> Void) {
        if isRealtimeConnected, let socket {
            do { try socketCommand(socket) } catch { fail(error.localizedDescription) }
            return
        }
        Task { await runAction("Sending command…") { try await rest(try requireClient()) } }
    }

    private func runAction(_ message: String, _ work: @MainActor @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        phase = .connecting(message)
        defer { isBusy = false }
        do {
            try await work()
            if isConnected { phase = .connected("Connected") }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func requireClient() throws -> SmartTubeClient {
        if let client { return client }
        guard let auth = token.trimmed.nilIfEmpty else { throw SmartTubeError.missingToken }
        let c = SmartTubeClient(config: SmartTubeConfig(host: host.trimmed, port: currentPort, token: auth))
        client = c
        return c
    }

    private func requireBridge() throws -> SmartTubeADBBridgeClient {
        if let bridge { return bridge }
        let b = try SmartTubeADBBridgeClient(host: bridgeHost.trimmed.nilIfEmpty ?? "127.0.0.1", port: currentBridgePort)
        b.connect()
        bridge = b
        return b
    }

    private func saveConnectionFields() {
        defaults.set(host.trimmed, forKey: "smarttube.host")
        defaults.set(apiPort.trimmed, forKey: "smarttube.port")
        defaults.set(bridgeHost.trimmed, forKey: "smarttube.bridge.host")
        defaults.set(bridgePort.trimmed, forKey: "smarttube.bridge.port")
        defaults.set(adbTVHost.trimmed, forKey: "smarttube.adb.tvhost")
        defaults.set(subnetPrefix.trimmed, forKey: "smarttube.subnet.prefix")
    }

    private func log(_ text: String) {
        connectionLog.append(text)
        if connectionLog.count > 8 { connectionLog.removeFirst(connectionLog.count - 8) }
    }

    private func fail(_ message: String) {
        lastError = message
        phase = .failed(message)
        log("Failed: \(message)")
    }

    static func formatTime(_ ms: Int) -> String {
        guard ms > 0 else { return "0:00" }
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var vm = SmartTubeControllerViewModel()
    @State private var seekValue: Double = 0
    @State private var isDraggingSeek = false
    @State private var theaterVolume: Double = 50
    @State private var subwooferLevel: Double = 6
    @State private var rearLevel: Double = 6

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
                .background(.thinMaterial)

            Divider()

            detail
                .frame(minWidth: 720, minHeight: 620)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await vm.autoDiscoverConnectAndPair() } } label: {
                    Label("Auto Connect", systemImage: "bolt.horizontal.circle.fill")
                }
                .disabled(vm.isBusy)

                Button { Task { try? await vm.refreshAll() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!vm.isConnected || vm.isBusy)

                Button { vm.connectRealtime() } label: {
                    Label("Realtime", systemImage: vm.isRealtimeConnected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                }
                .disabled(!vm.isConnected)
            }
        }
        .onAppear { vm.bootstrap() }
        .onReceive(vm.$playerState) { _ in
            if !isDraggingSeek { seekValue = vm.progress }
        }
        .onReceive(vm.$theaterState) { state in
            if let state { theaterVolume = Double(state.volume) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "play.tv.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SmartTube")
                        .font(.headline)
                    Text("macOS Remote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 16)

            statusCard
                .padding(.horizontal, 12)

            VStack(spacing: 4) {
                ForEach(SmartTubeControllerViewModel.Section.allCases) { section in
                    Button {
                        vm.selectedSection = section
                        if section == .tracks { Task { await vm.refreshTracks() } }
                        if section == .theater { Task { try? await vm.refreshAll(); await vm.refreshCEC() } }
                    } label: {
                        HStack {
                            Label(section.rawValue, systemImage: section.symbol)
                            Spacer()
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(vm.selectedSection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            connectionLog
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: vm.phase.systemImage)
                    .foregroundStyle(statusColor)
                Text(vm.phase.title)
                    .lineLimit(2)
                Spacer()
                if vm.phase.isWorking { ProgressView().controlSize(.small) }
            }
            .font(.callout)

            HStack(spacing: 8) {
                StatusPill(text: vm.isConnected ? "API" : "API off", active: vm.isConnected)
                StatusPill(text: vm.isRealtimeConnected ? "Live" : "Live off", active: vm.isRealtimeConnected)
                StatusPill(text: vm.isBridgeConnected ? "ADB" : "ADB off", active: vm.isBridgeConnected)
            }

            if let error = vm.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var statusColor: Color {
        switch vm.phase {
        case .connected: return .green
        case .failed: return .red
        case .needsPairing: return .orange
        case .connecting: return .blue
        case .idle: return .secondary
        }
    }

    private var connectionLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(vm.connectionLog.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch vm.selectedSection {
                case .remote:
                    remoteView
                case .queue:
                    queueView
                case .tracks:
                    tracksView
                case .theater:
                    theaterView
                case .settings:
                    settingsView
                }
            }
            .padding(24)
        }
    }

    private var remoteView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Remote", subtitle: "Control playback and send videos to SmartTube.")
            nowPlayingCard
            transportCard
            sendVideoCard
        }
    }

    private var nowPlayingCard: some View {
        Card {
            HStack(alignment: .top, spacing: 18) {
                thumbnail
                    .frame(width: 260, height: 146)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(vm.deviceTitle)
                            .font(.title2.weight(.semibold))
                            .lineLimit(2)
                        Spacer()
                        StatusPill(text: vm.playbackStateText, active: vm.playerState?.state == .playing)
                    }

                    Text(vm.deviceSubtitle)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        Slider(value: $seekValue, in: 0...1) { editing in
                            isDraggingSeek = editing
                            if !editing { vm.seek(toProgress: seekValue) }
                        }
                        HStack {
                            Text(vm.timeText)
                            Spacer()
                            Text("Vol \(vm.volumePercent)%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button { vm.seekRelative(-10_000) } label: { Label("-10s", systemImage: "gobackward.10") }
                        Button { vm.playPause() } label: { Label("Play/Pause", systemImage: vm.playerState?.state == .playing ? "pause.fill" : "play.fill") }
                            .buttonStyle(.borderedProminent)
                        Button { vm.seekRelative(10_000) } label: { Label("+10s", systemImage: "goforward.10") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = vm.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    ProgressView()
                }
            }
        } else {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.secondary.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transportCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Transport")
                    .font(.headline)
                HStack {
                    Button { vm.previous() } label: { Label("Previous", systemImage: "backward.end.fill") }
                    Button { vm.play() } label: { Label("Play", systemImage: "play.fill") }
                    Button { vm.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    Button { vm.next() } label: { Label("Next", systemImage: "forward.end.fill") }
                    Button(role: .destructive) { vm.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    Spacer()
                }

                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Playback volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(vm.volumePercent) },
                            set: { vm.setPlaybackVolume($0) }
                        ), in: 0...100)
                        .frame(width: 240)
                    }

                    VStack(alignment: .leading) {
                        Text("Speed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                                Button("\(speed, specifier: "%.2g")×") { vm.setSpeed(speed) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var sendVideoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Send to TV")
                    .font(.headline)

                HStack {
                    TextField("YouTube URL or video ID", text: $vm.videoInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Paste") { vm.videoInput = NSPasteboard.general.string(forType: .string) ?? vm.videoInput }
                    Button("Open") { Task { await vm.openVideo() } }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }

                HStack {
                    TextField("Search YouTube and play first result", text: $vm.searchInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Search & Play") { Task { await vm.searchAndPlay() } }
                }
            }
        }
    }

    private var queueView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Queue", subtitle: "Add videos and manage upcoming playback.")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Video ID", text: $vm.queueInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") { Task { await vm.addQueue() } }
                        Button("Play Next") { Task { await vm.playNextQueue() } }
                        Button("Refresh") { Task { try? await vm.refreshAll() } }
                        Button(role: .destructive) { Task { await vm.clearQueue() } } label: { Text("Clear") }
                    }

                    if vm.queue.isEmpty {
                        EmptyState(systemImage: "list.bullet.rectangle", title: "Queue is empty", message: "Add a YouTube video ID to build the queue.")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(vm.queue) { item in
                                HStack {
                                    Text("\(item.index ?? 0)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading) {
                                        Text(item.title ?? item.videoId ?? "Untitled")
                                            .lineLimit(1)
                                        Text(item.author ?? item.videoId ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.isCurrent == true { StatusPill(text: "Current", active: true) }
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                            }
                        }
                    }
                }
            }
        }
    }

    private var tracksView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Tracks", subtitle: "Switch quality, audio, and subtitles.")
            HStack(alignment: .top, spacing: 16) {
                formatList(title: "Video", items: vm.videoFormats.map { ($0.formatId, $0.label ?? videoFormatLabel($0), $0.isSelected == true) }) { id in
                    Task { await vm.selectVideoFormat(id) }
                }
                formatList(title: "Audio", items: vm.audioFormats.map { ($0.formatId, $0.languageLabel ?? $0.language ?? $0.codec ?? $0.formatId, $0.isSelected == true) }) { id in
                    Task { await vm.selectAudioFormat(id) }
                }
                subtitleList
            }
        }
    }

    private var subtitleList: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Subtitles").font(.headline)
                    Spacer()
                    Button("Off") { Task { await vm.selectSubtitleFormat(nil) } }
                }
                if vm.subtitleFormats.isEmpty {
                    EmptyState(systemImage: "captions.bubble", title: "No subtitles", message: "Refresh tracks after a video starts.")
                } else {
                    ForEach(vm.subtitleFormats) { item in
                        Button {
                            Task { await vm.selectSubtitleFormat(item.formatId) }
                        } label: {
                            HStack {
                                Text(item.languageLabel ?? item.language ?? item.formatId)
                                Spacer()
                                if item.isSelected == true { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formatList(title: String, items: [(String, String, Bool)], action: @escaping (String) -> Void) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                }
                if items.isEmpty {
                    EmptyState(systemImage: "slider.horizontal.3", title: "No \(title.lowercased()) tracks", message: "Click Refresh after playback starts.")
                } else {
                    ForEach(items, id: \.0) { item in
                        Button { action(item.0) } label: {
                            HStack {
                                Text(item.1).lineLimit(1)
                                Spacer()
                                if item.2 { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var theaterView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Theater", subtitle: "TV volume uses SmartTube API. CEC controls use the local ADB bridge.")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("TV Volume")
                            .font(.headline)
                        Spacer()
                        Text(vm.theaterState.map { "\($0.volume)%" } ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $theaterVolume, in: 0...100) { editing in
                        if !editing { Task { await vm.setTheaterVolume(theaterVolume) } }
                    }
                    HStack {
                        Button("Down") { Task { await vm.theaterVolumeStep(up: false) } }
                        Button("Mute") { Task { await vm.toggleTheaterMute() } }
                        Button("Up") { Task { await vm.theaterVolumeStep(up: true) } }
                        Button(role: .destructive) { Task { await vm.powerToggle() } } label: { Text("Power") }
                        Spacer()
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("HDMI CEC")
                            .font(.headline)
                        Spacer()
                        Button("Refresh CEC") { Task { await vm.refreshCEC() } }
                    }

                    HStack {
                        Button("Theater Speakers") { Task { await vm.setOutputTheater() } }
                        Button("TV Speakers") { Task { await vm.setOutputTV() } }
                        Menu("Sound Mode") {
                            ForEach(SmartTubeSoundMode.allCases, id: \.rawValue) { mode in
                                Button(mode.rawValue.capitalized) { Task { await vm.setSoundMode(mode) } }
                            }
                        }
                        Toggle("Immersive AE", isOn: Binding(
                            get: { vm.cecState?.immersiveAEEnabled ?? false },
                            set: { Task { await vm.setImmersive($0) } }
                        ))
                    }

                    VStack(alignment: .leading) {
                        Text("Subwoofer level: \(Int(subwooferLevel))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $subwooferLevel, in: 0...12, step: 1) { editing in
                            if !editing { Task { await vm.setSubwoofer(subwooferLevel) } }
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Rear level: \(Int(rearLevel))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $rearLevel, in: 0...12, step: 1) { editing in
                            if !editing { Task { await vm.setRear(rearLevel) } }
                        }
                    }

                    Text("Output: \(vm.cecState?.audioOutput.rawValue ?? "unknown") · Sub: \(vm.cecState?.subwooferLevel.map { String($0) } ?? "-") · Rear: \(vm.cecState?.rearLevel.map { String($0) } ?? "-") · Mode: \(vm.cecState?.soundMode?.rawValue ?? "-")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Settings", subtitle: "Manual fallback when discovery or auto-pairing fails.")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("SmartTube API")
                        .font(.headline)
                    HStack {
                        TextField("Host", text: $vm.host)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", text: $vm.apiPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("Connect") { Task { await vm.manualConnect() } }
                    }

                    HStack {
                        TextField("Pairing code", text: $vm.pairCodeInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Get Code") { Task { await vm.getPairCode() } }
                        Button("Pair") { Task { await vm.manualPair() } }
                            .buttonStyle(.borderedProminent)
                    }

                    if !vm.pairCodeFromTV.isEmpty {
                        Text("Current code: \(vm.pairCodeFromTV)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        SecureField("Token", text: $vm.token)
                            .textFieldStyle(.roundedBorder)
                        Button("Forget Token") { vm.forgetToken() }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ADB Bridge")
                        .font(.headline)
                    HStack {
                        TextField("Bridge host", text: $vm.bridgeHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", text: $vm.bridgePort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    HStack {
                        TextField("ADB TV host, optional", text: $vm.adbTVHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Subnet prefix", text: $vm.subnetPrefix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Button("Auto Discover") { Task { await vm.autoDiscoverConnectAndPair() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("For macOS, keep the Node bridge on ws://127.0.0.1:8498. If using ADB forwarding, SmartTube API becomes http://127.0.0.1:8497.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func videoFormatLabel(_ format: VideoFormat) -> String {
        var parts: [String] = []
        if let width = format.width, let height = format.height { parts.append("\(width)×\(height)") }
        if let fps = format.frameRate { parts.append("\(Int(fps))fps") }
        if let codec = format.codec { parts.append(codec.uppercased()) }
        return parts.isEmpty ? format.formatId : parts.joined(separator: " · ")
    }
}

// MARK: - Small Components

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
            )
    }
}

private struct StatusPill: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12)))
            .foregroundStyle(active ? Color.green : Color.secondary)
    }
}

private struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    ContentView()
}

SWIFT

# Clean old iOS-only SwiftUI modifiers if they exist anywhere after paste.
perl -0pi -e 's/\n\s*\.textInputAutocapitalization\(\.never\)//g; s/\n\s*\.keyboardType\(\.numberPad\)//g' "$CONTENT_VIEW"

echo "Replaced $CONTENT_VIEW"
echo "Backup saved next to the original file."
echo "Start ADB bridge: node bridge.js --port 8498"
echo "macOS sandbox: enable Outgoing Connections (Client)."

