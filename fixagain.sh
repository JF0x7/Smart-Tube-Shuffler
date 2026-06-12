#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT"

CV=""
for p in "SmartTubecontroller/ContentView.swift" "SmartTubecontroller/SmartTubecontroller/ContentView.swift" "ContentView.swift"; do
  if [ -f "$p" ]; then CV="$p"; break; fi
done

SDK=""
for p in "SmartTubecontroller/SmartTubeSDK.swift" "SmartTubecontroller/SmartTubecontroller/SmartTubeSDK.swift" "SmartTubeSDK.swift"; do
  if [ -f "$p" ]; then SDK="$p"; break; fi
done

if [ -z "$CV" ]; then
  echo "ContentView.swift not found. Run this from the project root."
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$CV" "$CV.bak.$STAMP"
echo "Backed up $CV"

if [ -n "$SDK" ]; then
  cp "$SDK" "$SDK.bak.$STAMP"
  python3 - "$SDK" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace(
    'private func command(_ path: String) async throws -> OKResponse {\n        try await request("POST", path, response: OKResponse.self)\n    }',
    'private func command(_ path: String) async throws -> OKResponse {\n        try await request("POST", path, body: EmptyBody(), response: OKResponse.self)\n    }'
)

s = s.replace('case deviceName = "device_name"\n        case deviceName = "device_name"', 'case deviceName = "device_name"')

replacement = r'''public enum PlayerStateValue: String, Codable, Sendable, Equatable {
    case playing
    case paused
    case buffering
    case idle
    case ended

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "idle"
        self = PlayerStateValue(rawValue: raw) ?? .idle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PlayerState: Codable, Sendable, Equatable {
    public let state: PlayerStateValue
    public let video: VideoInfo?
    public let positionMs: Int?
    public let durationMs: Int?
    public let speed: Double?
    public let pitch: Double?
    public let volume: Double?
    public let selectedTracks: SelectedTracks?
    public let videoTransform: VideoTransform?
    public let suggestionsCount: Int?
    public let queueSize: Int?
    public let queueIndex: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case video
        case positionMs = "position_ms"
        case durationMs = "duration_ms"
        case speed
        case pitch
        case volume
        case selectedTracks = "selected_tracks"
        case videoTransform = "video_transform"
        case suggestionsCount = "suggestions_count"
        case queueSize = "queue_size"
        case queueIndex = "queue_index"
    }

    public init(
        state: PlayerStateValue = .idle,
        video: VideoInfo? = nil,
        positionMs: Int? = nil,
        durationMs: Int? = nil,
        speed: Double? = nil,
        pitch: Double? = nil,
        volume: Double? = nil,
        selectedTracks: SelectedTracks? = nil,
        videoTransform: VideoTransform? = nil,
        suggestionsCount: Int? = nil,
        queueSize: Int? = nil,
        queueIndex: Int? = nil
    ) {
        self.state = state
        self.video = video
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.speed = speed
        self.pitch = pitch
        self.volume = volume
        self.selectedTracks = selectedTracks
        self.videoTransform = videoTransform
        self.suggestionsCount = suggestionsCount
        self.queueSize = queueSize
        self.queueIndex = queueIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = (try? c.decodeIfPresent(PlayerStateValue.self, forKey: .state)) ?? .idle
        self.video = (try? c.decodeIfPresent(VideoInfo.self, forKey: .video)) ?? nil
        self.positionMs = (try? c.decodeIfPresent(Int.self, forKey: .positionMs)) ?? nil
        self.durationMs = (try? c.decodeIfPresent(Int.self, forKey: .durationMs)) ?? nil
        self.speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? nil
        self.pitch = (try? c.decodeIfPresent(Double.self, forKey: .pitch)) ?? nil
        self.volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? nil
        self.selectedTracks = (try? c.decodeIfPresent(SelectedTracks.self, forKey: .selectedTracks)) ?? nil
        self.videoTransform = (try? c.decodeIfPresent(VideoTransform.self, forKey: .videoTransform)) ?? nil
        self.suggestionsCount = (try? c.decodeIfPresent(Int.self, forKey: .suggestionsCount)) ?? nil
        self.queueSize = (try? c.decodeIfPresent(Int.self, forKey: .queueSize)) ?? nil
        self.queueIndex = (try? c.decodeIfPresent(Int.self, forKey: .queueIndex)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(video, forKey: .video)
        try c.encodeIfPresent(positionMs, forKey: .positionMs)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(pitch, forKey: .pitch)
        try c.encodeIfPresent(volume, forKey: .volume)
        try c.encodeIfPresent(selectedTracks, forKey: .selectedTracks)
        try c.encodeIfPresent(videoTransform, forKey: .videoTransform)
        try c.encodeIfPresent(suggestionsCount, forKey: .suggestionsCount)
        try c.encodeIfPresent(queueSize, forKey: .queueSize)
        try c.encodeIfPresent(queueIndex, forKey: .queueIndex)
    }
}

'''

s, n = re.subn(
    r'public enum PlayerStateValue: String, Codable, Sendable(?:, Equatable)? \{.*?\n\}\n\npublic struct PlayerState: Codable, Sendable, Equatable \{.*?\n\}\n\n(?=public struct VideoInfo)',
    replacement,
    s,
    count=1,
    flags=re.S
)
if n == 0:
    print('Warning: PlayerState block not patched')

s = s.replace(
    'data = try container.decodeIfPresent(PlayerState.self, forKey: .data)\n        rawData = try container.decodeIfPresent(JSONValue.self, forKey: .data)',
    'data = (try? container.decodeIfPresent(PlayerState.self, forKey: .data)) ?? nil\n        rawData = (try? container.decodeIfPresent(JSONValue.self, forKey: .data)) ?? nil'
)

theater_replacement = r'''public struct TheaterState: Codable, Sendable, Equatable {
    public let volume: Int
    public let muted: Bool
    public let audioOutput: String?

    enum CodingKeys: String, CodingKey {
        case volume
        case muted
        case audioOutput = "audio_output"
    }

    public init(volume: Int = 0, muted: Bool = false, audioOutput: String? = nil) {
        self.volume = volume
        self.muted = muted
        self.audioOutput = audioOutput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.volume = (try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? 0
        self.muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        self.audioOutput = (try? c.decodeIfPresent(String.self, forKey: .audioOutput)) ?? nil
    }
}

'''
s, n = re.subn(
    r'public struct TheaterState: Codable, Sendable, Equatable \{.*?\n\}\n\n(?=public struct TheaterVolumeState)',
    theater_replacement,
    s,
    count=1,
    flags=re.S
)
if n == 0:
    print('Warning: TheaterState block not patched')

p.write_text(s)
print(f'Patched {p}')
PY
else
  echo "Warning: SmartTubeSDK.swift not found; only ContentView.swift will be replaced."
fi

cat > "$CV" <<'SWIFT'
//
//  ContentView.swift
//  SmartTubecontroller
//
//  Clean macOS UI for SmartTube Remote API + ADB Bridge.
//  Requires SmartTubeSDK.swift and SmartTubeADBBridge.swift in the same target.
//

import SwiftUI
import AppKit

@MainActor
final class SmartTubeControllerViewModel: ObservableObject {
    enum Screen: String, CaseIterable, Identifiable {
        case remote = "Remote"
        case queue = "Queue"
        case tracks = "Tracks"
        case theater = "Theater"
        case settings = "Settings"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .remote: return "play.rectangle.fill"
            case .queue: return "list.bullet.rectangle"
            case .tracks: return "slider.horizontal.3"
            case .theater: return "hifispeaker.2.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case connected(String)
        case needsPairing(String)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Ready"
            case .working(let value): return value
            case .connected(let value): return value
            case .needsPairing(let value): return value
            case .failed(let value): return value
            }
        }

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var icon: String {
            switch self {
            case .idle: return "circle"
            case .working: return "arrow.triangle.2.circlepath"
            case .connected: return "checkmark.circle.fill"
            case .needsPairing: return "key.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published var selectedScreen: Screen = .remote

    @Published var host: String
    @Published var apiPort: String
    @Published var token: String
    @Published var bridgeHost: String
    @Published var bridgePort: String
    @Published var adbTVHost: String
    @Published var subnetPrefix: String

    @Published var pairCodeFromTV: String = ""
    @Published var pairCodeInput: String = ""
    @Published var videoInput: String = ""
    @Published var searchInput: String = ""
    @Published var queueInput: String = ""

    @Published var phase: Phase = .idle
    @Published var bridgePhase: Phase = .idle
    @Published var isBusy: Bool = false
    @Published var isConnected: Bool = false
    @Published var isRealtimeConnected: Bool = false
    @Published var isBridgeConnected: Bool = false
    @Published var lastError: String?

    @Published var playerState: PlayerState?
    @Published var queueItems: [QueueItem] = []
    @Published var videoFormats: [VideoFormat] = []
    @Published var audioFormats: [AudioFormat] = []
    @Published var subtitleFormats: [SubtitleFormat] = []
    @Published var theaterState: TheaterState?
    @Published var cecState: SmartTubeCECState?
    @Published var logs: [String] = []

    private var client: SmartTubeClient?
    private var realtime: SmartTubeWebSocketClient?
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

    var apiPortInt: Int { Int(apiPort.trimmed) ?? 8497 }
    var bridgePortInt: Int { Int(bridgePort.trimmed) ?? 8498 }

    var titleText: String {
        if let title = playerState?.video?.title, !title.isEmpty { return title }
        return isConnected ? "Connected — no video loaded" : "Not connected"
    }

    var subtitleText: String {
        if let author = playerState?.video?.author, !author.isEmpty { return author }
        return "\(host.trimmed):\(apiPortInt)"
    }

    var thumbnailURL: URL? {
        guard let raw = playerState?.video?.thumbnailURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var positionMs: Int { playerState?.positionMs ?? 0 }
    var durationMs: Int { playerState?.durationMs ?? playerState?.video?.durationMs ?? 0 }
    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }
    var timeText: String { "\(Self.formatTime(positionMs)) / \(Self.formatTime(durationMs))" }
    var volumePercent: Int { Int(((playerState?.volume ?? 0) * 100).rounded()) }
    var tokenRedacted: String {
        let value = token.trimmed
        guard value.count > 8 else { return value.isEmpty ? "none" : "set" }
        return String(value.prefix(6)) + "…" + String(value.suffix(4))
    }

    var diagnosticsText: String {
        let lines = [
            "SmartTube controller diagnostics",
            "API: \(host.trimmed):\(apiPortInt)",
            "Bridge: \(bridgeHost.trimmed):\(bridgePortInt)",
            "Token: \(tokenRedacted)",
            "Connected: api=\(isConnected), realtime=\(isRealtimeConnected), bridge=\(isBridgeConnected)",
            "Phase: \(phase.text)",
            "Bridge phase: \(bridgePhase.text)",
            "Player: \(playerState?.state.rawValue ?? "nil") pos=\(positionMs) dur=\(durationMs)",
            "Video: \(playerState?.video?.title ?? "nil")",
            "Theater: volume=\(theaterState?.volume.description ?? "nil") muted=\(theaterState?.muted.description ?? "nil") output=\(theaterState?.audioOutput ?? "nil")",
            "CEC: output=\(cecState?.audioOutput.rawValue ?? "nil") sub=\(cecState?.subwooferLevel?.description ?? "nil") rear=\(cecState?.rearLevel?.description ?? "nil") immersive=\(cecState?.immersiveAEEnabled?.description ?? "nil") mode=\(cecState?.soundMode?.rawValue ?? "nil")",
            "Last error: \(lastError ?? "none")",
            "",
            "Log:",
            logs.joined(separator: "\n")
        ]
        return lines.joined(separator: "\n")
    }

    func bootstrap() {
        Task { await self.autoConnect() }
    }

    func autoConnect() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        logs.removeAll()
        defer { isBusy = false }

        log("Starting auto connect")

        if await tryADBForward() {
            if await connectAndPairIfNeeded(host: host.trimmed, port: apiPortInt, source: "ADB forward") {
                return
            }
        }

        if await connectAndPairIfNeeded(host: host.trimmed, port: apiPortInt, source: "saved address") {
            return
        }

        if await tryUDPDiscovery() {
            return
        }

        if await trySubnetScan() {
            return
        }

        let message = "Could not auto connect. Start bridge with `node bridge.js --port 8498`, make sure ADB sees the TV, or enter the TV IP manually."
        lastError = message
        phase = .failed("Auto connect failed")
        log(message)
    }

    @discardableResult
    private func tryADBForward() async -> Bool {
        bridgePhase = .working("Checking ADB bridge…")
        let bridgeHostValue = bridgeHost.trimmed.isEmpty ? "127.0.0.1" : bridgeHost.trimmed
        let bridgePortValue = bridgePortInt

        do {
            let newBridge = try SmartTubeADBBridgeClient(host: bridgeHostValue, port: bridgePortValue)
            newBridge.connect()
            _ = try await newBridge.ping()
            bridge = newBridge
            isBridgeConnected = true
            bridgePhase = .connected("ADB bridge connected")
            log("ADB bridge connected at ws://\(bridgeHostValue):\(bridgePortValue)")

            let tvHost = adbTVHost.trimmed
            if !tvHost.isEmpty {
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
            saveSettings()
            let deviceName = info.model.isEmpty ? info.serial : info.model
            log("Forwarded SmartTube API from \(deviceName) to \(info.host):\(info.port)")
            return true
        } catch {
            isBridgeConnected = false
            bridgePhase = .failed("ADB bridge unavailable")
            log("ADB bridge failed: \(error.localizedDescription)")
            return false
        }
    }

    private func tryUDPDiscovery() async -> Bool {
        phase = .working("Discovering on LAN…")
        log("Trying UDP discovery on port \(apiPortInt)")
        do {
            let devices = try await SmartTubeDiscovery.discoverUDP(port: apiPortInt, timeout: 2.0)
            for device in devices {
                guard let foundHost = device.host else { continue }
                log("Discovered \(device.deviceName) at \(foundHost):\(device.apiPort)")
                if await connectAndPairIfNeeded(host: foundHost, port: device.apiPort, source: device.deviceName) {
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
        phase = .working("Scanning \(prefix).x…")
        log("Scanning \(prefix).1-254")

        let found = await SmartTubeDiscovery.scanSubnet(prefix: prefix, port: apiPortInt, timeout: 0.45, maxConcurrent: 48)
        for item in found {
            log("Found SmartTube at \(item.host):\(apiPortInt)")
            if await connectAndPairIfNeeded(host: item.host, port: apiPortInt, source: "subnet scan") {
                return true
            }
        }
        log("Subnet scan found nothing")
        return false
    }

    @discardableResult
    private func connectAndPairIfNeeded(host targetHost: String, port targetPort: Int, source: String) async -> Bool {
        let targetHost = targetHost.trimmed
        guard !targetHost.isEmpty else { return false }

        phase = .working("Connecting via \(source)…")
        host = targetHost
        apiPort = String(targetPort)
        saveSettings()

        do {
            let pingClient = SmartTubeClient(config: SmartTubeConfig(host: targetHost, port: targetPort))
            let ping = try await pingClient.ping()
            log("Ping OK: \(ping.deviceName)")

            if let savedToken = token.trimmed.nilIfEmpty {
                do {
                    let authed = SmartTubeClient(config: SmartTubeConfig(host: targetHost, port: targetPort, token: savedToken))
                    _ = try await authed.getPlayer()
                    client = authed
                    isConnected = true
                    phase = .connected("Connected to \(ping.deviceName)")
                    log("Saved token accepted")
                    await afterConnected()
                    return true
                } catch {
                    log("Saved token failed: \(error.localizedDescription)")
                    token = ""
                    defaults.removeObject(forKey: "smarttube.token")
                }
            }

            do {
                let pair = try await pingClient.getPairCode()
                pairCodeFromTV = pair.code
                log("Got pair code \(pair.code)")
                let verified = try await verifyPairCode(using: pingClient, code: pair.code)
                token = verified.token
                defaults.set(verified.token, forKey: "smarttube.token")
                client = SmartTubeClient(config: SmartTubeConfig(host: targetHost, port: targetPort, token: verified.token))
                isConnected = true
                phase = .connected("Paired with \(verified.deviceName)")
                log("Auto-pair OK")
                await afterConnected()
                return true
            } catch {
                phase = .needsPairing("Manual pairing needed")
                lastError = "Auto-pair failed: \(error.localizedDescription). Enter the code shown on the TV or press Get Code."
                log(lastError ?? "Auto-pair failed")
                return false
            }
        } catch {
            log("Connect failed for \(targetHost):\(targetPort): \(error.localizedDescription)")
            return false
        }
    }

    private func verifyPairCode(using client: SmartTubeClient, code: String) async throws -> PairVerifyResponse {
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

        var last: Error?
        for candidate in candidates {
            do { return try await client.verifyPairCode(candidate) }
            catch { last = error }
        }
        throw last ?? SmartTubeError.emptyResponse
    }

    private func afterConnected() async {
        saveSettings()
        await refreshAllTolerant()
        connectRealtime()
    }

    func manualConnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        _ = await connectAndPairIfNeeded(host: host.trimmed, port: apiPortInt, source: "manual")
    }

    func getPairCode() async {
        phase = .working("Getting pair code…")
        do {
            let c = SmartTubeClient(config: SmartTubeConfig(host: host.trimmed, port: apiPortInt))
            let response = try await c.getPairCode()
            pairCodeFromTV = response.code
            phase = .needsPairing("Enter pairing code")
            log("Pair code requested: \(response.code), expires in \(response.expiresIn)s")
        } catch {
            fail("Could not get pair code: \(error.localizedDescription)")
        }
    }

    func manualPair() async {
        let input = pairCodeInput.trimmed.nilIfEmpty ?? pairCodeFromTV.trimmed
        guard !input.isEmpty else {
            fail("Enter the pairing code first")
            return
        }
        phase = .working("Pairing…")
        do {
            let c = SmartTubeClient(config: SmartTubeConfig(host: host.trimmed, port: apiPortInt))
            let verified = try await verifyPairCode(using: c, code: input)
            token = verified.token
            defaults.set(verified.token, forKey: "smarttube.token")
            client = SmartTubeClient(config: SmartTubeConfig(host: host.trimmed, port: apiPortInt, token: verified.token))
            isConnected = true
            phase = .connected("Paired with \(verified.deviceName)")
            log("Manual pair OK")
            await afterConnected()
        } catch {
            fail("Pair failed: \(error.localizedDescription)")
        }
    }

    func connectRealtime() {
        realtime?.disconnect()
        guard let auth = token.trimmed.nilIfEmpty else {
            isRealtimeConnected = false
            log("Realtime skipped: no token")
            return
        }

        let socket = SmartTubeWebSocketClient(config: SmartTubeConfig(host: host.trimmed, port: apiPortInt, token: auth))
        socket.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .hello(_, let deviceName):
                    self.isRealtimeConnected = true
                    self.log("Realtime connected\(deviceName.map { " to \($0)" } ?? "")")
                case .stateUpdate(let state):
                    self.playerState = state
                    self.isRealtimeConnected = true
                case .json(let json):
                    self.log("Realtime JSON: \(String(describing: json))")
                }
            }
        }
        socket.onError = { [weak self] error in
            Task { @MainActor in
                self?.isRealtimeConnected = false
                self?.lastError = "Realtime error: \(error.localizedDescription)"
                self?.log(self?.lastError ?? "Realtime error")
            }
        }
        socket.onClose = { [weak self] in
            Task { @MainActor in
                self?.isRealtimeConnected = false
                self?.log("Realtime closed")
            }
        }

        do {
            try socket.connect()
            realtime = socket
            isRealtimeConnected = true
            log("Realtime connecting")
        } catch {
            isRealtimeConnected = false
            log("Realtime connect failed: \(error.localizedDescription)")
        }
    }

    func refreshAllTolerant() async {
        guard let client else { return }
        phase = isConnected ? phase : .working("Refreshing…")

        do {
            playerState = try await client.getPlayer()
            log("Player refreshed: \(playerState?.state.rawValue ?? "unknown")")
        } catch {
            log("Player refresh failed: \(error.localizedDescription)")
        }

        do {
            queueItems = try await client.getQueue()
            log("Queue refreshed: \(queueItems.count) items")
        } catch {
            log("Queue refresh skipped: \(error.localizedDescription)")
        }

        do {
            theaterState = try await client.getTheater()
            log("Theater refreshed: volume \(theaterState?.volume ?? 0)")
        } catch {
            log("Theater refresh skipped: \(error.localizedDescription)")
        }
    }

    func refreshTracks() async {
        guard let client else { return }
        do { videoFormats = try await client.getVideoFormats() } catch { log("Video formats failed: \(error.localizedDescription)") }
        do { audioFormats = try await client.getAudioFormats() } catch { log("Audio formats failed: \(error.localizedDescription)") }
        do { subtitleFormats = try await client.getSubtitleFormats() } catch { log("Subtitle formats failed: \(error.localizedDescription)") }
    }

    func refreshCEC() async {
        guard let bridge else { log("CEC refresh skipped: bridge not connected"); return }
        do {
            cecState = try await bridge.getParsedCECState()
            log("CEC refreshed")
        } catch {
            log("CEC refresh failed: \(error.localizedDescription)")
        }
    }

    func playPause() async {
        await run("Play/Pause") { client in
            _ = try await client.toggle()
            try? self.realtime?.getState()
        }
    }

    func play() async { await run("Play") { client in _ = try await client.play(); try? self.realtime?.getState() } }
    func pause() async { await run("Pause") { client in _ = try await client.pause(); try? self.realtime?.getState() } }
    func previous() async { await run("Previous") { client in _ = try await client.previous(); try? self.realtime?.getState() } }
    func next() async { await run("Next") { client in _ = try await client.next(); try? self.realtime?.getState() } }
    func stop() async { await run("Stop") { client in _ = try await client.stop(); try? self.realtime?.getState() } }

    func seekBy(seconds: Int) async {
        let target = max(0, positionMs + seconds * 1000)
        await run("Seek \(seconds)s") { client in
            _ = try await client.seek(positionMs: target)
            try? self.realtime?.getState()
        }
    }

    func setSpeed(_ speed: Double) async {
        await run("Set speed \(speed)x") { client in
            _ = try await client.setSpeed(speed)
            try? self.realtime?.getState()
        }
    }

    func setPlaybackVolume(_ percent: Int) async {
        let clamped = max(0, min(100, percent))
        await run("Set playback volume \(clamped)%") { client in
            _ = try await client.setVolume(Double(clamped) / 100.0)
            try? self.realtime?.getState()
        }
    }

    func openVideo() async {
        let input = videoInput.trimmed
        guard !input.isEmpty else { fail("Paste a YouTube URL or video ID first"); return }
        await run("Open video") { client in
            if input.contains("/") || input.contains("youtu") {
                _ = try await client.openURL(input)
            } else {
                _ = try await client.openVideoId(input)
            }
            self.videoInput = ""
            try? self.realtime?.getState()
            await self.refreshAllTolerant()
        }
    }

    func searchAndPlay() async {
        let query = searchInput.trimmed
        guard !query.isEmpty else { fail("Enter a search query first"); return }
        await run("Search and play") { client in
            _ = try await client.searchAndPlay(query)
            try? self.realtime?.getState()
            await self.refreshAllTolerant()
        }
    }

    func addQueue(next: Bool) async {
        let id = queueInput.trimmed
        guard !id.isEmpty else { fail("Enter a video ID first"); return }
        await run(next ? "Play next" : "Add to queue") { client in
            if next { _ = try await client.playNext(videoId: id) }
            else { _ = try await client.addToQueue(videoId: id) }
            self.queueInput = ""
            await self.refreshAllTolerant()
        }
    }

    func clearQueue() async {
        await run("Clear queue") { client in
            _ = try await client.clearQueue()
            await self.refreshAllTolerant()
        }
    }

    func setVideoFormat(_ id: String) async { await run("Set video format") { client in _ = try await client.setVideoFormat(id); await self.refreshTracks() } }
    func setAudioFormat(_ id: String) async { await run("Set audio format") { client in _ = try await client.setAudioFormat(id); await self.refreshTracks() } }
    func setSubtitleFormat(_ id: String?) async { await run("Set subtitle") { client in _ = try await client.setSubtitleFormat(id); await self.refreshTracks() } }

    func tvVolumeUp() async { await run("TV volume up") { client in _ = try await client.theaterVolumeUp(); await self.refreshAllTolerant() } }
    func tvVolumeDown() async { await run("TV volume down") { client in _ = try await client.theaterVolumeDown(); await self.refreshAllTolerant() } }
    func tvMute() async { await run("TV mute") { client in _ = try await client.toggleTheaterMute(); await self.refreshAllTolerant() } }
    func setTVVolume(_ value: Int) async { await run("Set TV volume") { client in _ = try await client.setTheaterVolume(value); await self.refreshAllTolerant() } }

    func powerToggle() async {
        if let bridge {
            do {
                _ = try await bridge.powerToggle()
                log("Power toggle sent by ADB")
            } catch {
                log("ADB power failed, trying REST: \(error.localizedDescription)")
                await run("Power toggle") { client in _ = try await client.toggleTheaterPower() }
            }
        } else {
            await run("Power toggle") { client in _ = try await client.toggleTheaterPower() }
        }
    }

    func setOutputTheater() async {
        guard let bridge else { fail("ADB bridge not connected"); return }
        await runBridge("Theater speakers") { _ = try await bridge.setHomeTheaterSpeakers() }
    }

    func setOutputTV() async {
        guard let bridge else { fail("ADB bridge not connected"); return }
        await runBridge("TV speakers") { _ = try await bridge.setTVSpeakers() }
    }

    func setSubwoofer(_ level: Int) async {
        guard let bridge else { fail("ADB bridge not connected"); return }
        await runBridge("Set subwoofer") { _ = try await bridge.setSubwooferLevel(level) }
    }

    func setRear(_ level: Int) async {
        guard let bridge else { fail("ADB bridge not connected"); return }
        await runBridge("Set rear") { _ = try await bridge.setRearLevel(level) }
    }

    func setImmersive(_ enabled: Bool) async {
        guard let bridge else { fail("ADB bridge not connected"); return }
        await runBridge("Set immersive AE") { _ = try await bridge.setImmersiveAE(enabled) }
    }

    func setSoundMode(_ mode: SmartTubeSoundMode) async {
        guard let bridge else { fail("ADB bridge not connected"); return }
        await runBridge("Set sound mode") { _ = try await bridge.setSoundMode(mode) }
    }

    func saveSettings() {
        defaults.set(host.trimmed, forKey: "smarttube.host")
        defaults.set(String(apiPortInt), forKey: "smarttube.port")
        defaults.set(bridgeHost.trimmed, forKey: "smarttube.bridge.host")
        defaults.set(String(bridgePortInt), forKey: "smarttube.bridge.port")
        defaults.set(adbTVHost.trimmed, forKey: "smarttube.adb.tvhost")
        defaults.set(subnetPrefix.trimmed, forKey: "smarttube.subnet.prefix")
        if !token.trimmed.isEmpty { defaults.set(token.trimmed, forKey: "smarttube.token") }
    }

    func forgetToken() {
        token = ""
        defaults.removeObject(forKey: "smarttube.token")
        realtime?.disconnect()
        realtime = nil
        isRealtimeConnected = false
        phase = .needsPairing("Token removed")
        log("Token removed")
    }

    func disconnect() {
        realtime?.disconnect()
        realtime = nil
        client = nil
        isConnected = false
        isRealtimeConnected = false
        phase = .idle
        log("Disconnected")
    }

    func copyLogsToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsText, forType: .string)
        log("Copied diagnostics to clipboard")
    }

    private func run(_ name: String, _ block: @MainActor @escaping (SmartTubeClient) async throws -> Void) async {
        guard let client else { fail("Not connected"); return }
        do {
            log("\(name)…")
            try await block(client)
            log("\(name) OK")
        } catch {
            fail("\(name) failed: \(error.localizedDescription)")
        }
    }

    private func runBridge(_ name: String, _ block: @escaping () async throws -> Void) async {
        do {
            log("\(name)…")
            try await block()
            log("\(name) OK")
            await refreshCEC()
        } catch {
            fail("\(name) failed: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        lastError = message
        phase = .failed(message)
        log("Failed: \(message)")
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    static func formatTime(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

struct ContentView: View {
    @StateObject private var vm = SmartTubeControllerViewModel()
    @State private var didBootstrap = false
    @State private var playbackVolumeDraft: Double = 0
    @State private var tvVolumeDraft: Double = 50
    @State private var subwooferDraft: Double = 6
    @State private var rearDraft: Double = 6

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
            guard !self.didBootstrap else { return }
            self.didBootstrap = true
            self.vm.bootstrap()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "play.tv.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
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
                ForEach(SmartTubeControllerViewModel.Screen.allCases) { screen in
                    Button {
                        self.vm.selectedScreen = screen
                        if screen == .tracks { Task { await self.vm.refreshTracks() } }
                        if screen == .theater { Task { await self.vm.refreshAllTolerant(); await self.vm.refreshCEC() } }
                    } label: {
                        HStack {
                            Label(screen.rawValue, systemImage: screen.icon)
                            Spacer()
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(self.vm.selectedScreen == screen ? Color.accentColor.opacity(0.16) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            logPanel
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: self.vm.phase.icon)
                    .foregroundStyle(statusColor)
                Text(self.vm.phase.text)
                    .lineLimit(2)
                Spacer()
                if self.vm.phase.isWorking { ProgressView().controlSize(.small) }
            }
            .font(.callout)

            HStack(spacing: 6) {
                StatusPill(text: self.vm.isConnected ? "API" : "API off", active: self.vm.isConnected)
                StatusPill(text: self.vm.isRealtimeConnected ? "Live" : "Live off", active: self.vm.isRealtimeConnected)
                StatusPill(text: self.vm.isBridgeConnected ? "ADB" : "ADB off", active: self.vm.isBridgeConnected)
            }

            if let error = self.vm.lastError, !error.isEmpty {
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
        switch self.vm.phase {
        case .idle: return .secondary
        case .working: return .blue
        case .connected: return .green
        case .needsPairing: return .orange
        case .failed: return .red
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connection log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { self.vm.copyLogsToClipboard() }
                    .font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(self.vm.logs.suffix(12).enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch self.vm.selectedScreen {
                    case .remote: remoteView
                    case .queue: queueView
                    case .tracks: tracksView
                    case .theater: theaterView
                    case .settings: settingsView
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 10) {
            Text(self.vm.selectedScreen.rawValue)
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Auto Connect") { Task { await self.vm.autoConnect() } }
            Button("Refresh") { Task { await self.vm.refreshAllTolerant() } }
            Button("Copy Logs") { self.vm.copyLogsToClipboard() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var remoteView: some View {
        VStack(alignment: .leading, spacing: 18) {
            nowPlayingCard
            transportCard
            sendCard
        }
    }

    private var nowPlayingCard: some View {
        Card {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(0.16))
                    if let url = self.vm.thumbnailURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                    } else {
                        Image(systemName: "play.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(self.vm.titleText)
                                .font(.headline)
                                .lineLimit(2)
                            Text(self.vm.subtitleText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(self.vm.playerState?.state.rawValue.capitalized ?? "Idle")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }

                    ProgressView(value: self.vm.progress)
                    HStack {
                        Text(self.vm.timeText)
                        Spacer()
                        Text("Vol \(self.vm.volumePercent)%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("−10s") { Task { await self.vm.seekBy(seconds: -10) } }
                        Button {
                            Task { await self.vm.playPause() }
                        } label: {
                            Label("Play/Pause", systemImage: "playpause.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("+10s") { Task { await self.vm.seekBy(seconds: 10) } }
                    }
                }
            }
        }
    }

    private var transportCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Transport")
                    .font(.headline)
                HStack(spacing: 8) {
                    Button("Previous") { Task { await self.vm.previous() } }
                    Button("Play") { Task { await self.vm.play() } }
                    Button("Pause") { Task { await self.vm.pause() } }
                    Button("Next") { Task { await self.vm.next() } }
                    Button("Stop") { Task { await self.vm.stop() } }
                    Spacer()
                }

                Divider()

                HStack(spacing: 14) {
                    VStack(alignment: .leading) {
                        Text("Playback volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Slider(value: self.$playbackVolumeDraft, in: 0...100)
                                .frame(width: 260)
                            Button("Apply") {
                                Task { await self.vm.setPlaybackVolume(Int(self.playbackVolumeDraft.rounded())) }
                            }
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Speed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                                Button("\(String(format: "%g", speed))×") { Task { await self.vm.setSpeed(speed) } }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { self.playbackVolumeDraft = Double(self.vm.volumePercent) }
    }

    private var sendCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send to TV")
                    .font(.headline)
                HStack {
                    TextField("YouTube URL or video ID", text: self.$vm.videoInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Paste") {
                        self.vm.videoInput = NSPasteboard.general.string(forType: .string) ?? self.vm.videoInput
                    }
                    Button("Open") { Task { await self.vm.openVideo() } }
                        .buttonStyle(.borderedProminent)
                }
                HStack {
                    TextField("Search YouTube and play first result", text: self.$vm.searchInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Search & Play") { Task { await self.vm.searchAndPlay() } }
                }
            }
        }
    }

    private var queueView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Queue")
                            .font(.headline)
                        Spacer()
                        Button("Refresh") { Task { await self.vm.refreshAllTolerant() } }
                        Button("Clear") { Task { await self.vm.clearQueue() } }
                    }

                    HStack {
                        TextField("Video ID", text: self.$vm.queueInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") { Task { await self.vm.addQueue(next: false) } }
                        Button("Play Next") { Task { await self.vm.addQueue(next: true) } }
                    }
                }
            }

            Card {
                if self.vm.queueItems.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "list.bullet.rectangle", description: Text("Add a video ID or refresh after playback starts."))
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(self.vm.queueItems) { item in
                            HStack {
                                Text("\(item.index ?? 0)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text(item.title ?? item.videoId ?? "Untitled")
                                        .lineLimit(1)
                                    Text(item.author ?? item.videoId ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.isCurrent == true {
                                    Text("Current")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var tracksView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Tracks")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh Tracks") { Task { await self.vm.refreshTracks() } }
            }

            trackSection(title: "Video", items: self.vm.videoFormats.map { format in
                TrackRow(id: format.formatId, title: format.label ?? "\(format.height.map { "\($0)p" } ?? "Video")", subtitle: [format.codec, format.bitrate.map { "\($0) bps" }].compactMap { $0 }.joined(separator: " · "), selected: format.isSelected == true)
            }, action: { id in Task { await self.vm.setVideoFormat(id) } })

            trackSection(title: "Audio", items: self.vm.audioFormats.map { format in
                TrackRow(id: format.formatId, title: format.languageLabel ?? format.language ?? format.codec ?? format.formatId, subtitle: [format.codec, format.bitrate.map { "\($0) bps" }].compactMap { $0 }.joined(separator: " · "), selected: format.isSelected == true)
            }, action: { id in Task { await self.vm.setAudioFormat(id) } })

            trackSection(title: "Subtitles", items: self.vm.subtitleFormats.map { format in
                TrackRow(id: format.formatId, title: format.languageLabel ?? format.language ?? format.formatId, subtitle: format.formatId, selected: format.isSelected == true)
            }, action: { id in Task { await self.vm.setSubtitleFormat(id) } })

            Button("Disable Subtitles") { Task { await self.vm.setSubtitleFormat(nil) } }
        }
    }

    private func trackSection(title: String, items: [TrackRow], action: @escaping (String) -> Void) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                if items.isEmpty {
                    Text("No formats loaded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if item.selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Button("Use") { action(item.id) }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var theaterView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("TV Audio")
                            .font(.headline)
                        Spacer()
                        Text(self.vm.theaterState.map { "\($0.volume)%" } ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Volume Down") { Task { await self.vm.tvVolumeDown() } }
                        Button("Mute") { Task { await self.vm.tvMute() } }
                        Button("Volume Up") { Task { await self.vm.tvVolumeUp() } }
                        Button("Power") { Task { await self.vm.powerToggle() } }
                        Spacer()
                    }
                    HStack {
                        Slider(value: self.$tvVolumeDraft, in: 0...100)
                            .frame(width: 300)
                        Button("Set Volume") { Task { await self.vm.setTVVolume(Int(self.tvVolumeDraft.rounded())) } }
                    }
                }
            }
            .onAppear { self.tvVolumeDraft = Double(self.vm.theaterState?.volume ?? 50) }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("HDMI CEC via ADB Bridge")
                            .font(.headline)
                        Spacer()
                        Button("Refresh CEC") { Task { await self.vm.refreshCEC() } }
                    }
                    HStack {
                        Button("Theater Speakers") { Task { await self.vm.setOutputTheater() } }
                        Button("TV Speakers") { Task { await self.vm.setOutputTV() } }
                        Menu("Sound Mode") {
                            ForEach(SmartTubeSoundMode.allCases, id: \.rawValue) { mode in
                                Button(mode.rawValue.capitalized) { Task { await self.vm.setSoundMode(mode) } }
                            }
                        }
                        Toggle("Immersive AE", isOn: Binding(
                            get: { self.vm.cecState?.immersiveAEEnabled ?? false },
                            set: { enabled in Task { await self.vm.setImmersive(enabled) } }
                        ))
                    }
                    HStack(spacing: 18) {
                        VStack(alignment: .leading) {
                            Text("Subwoofer: \(Int(self.subwooferDraft))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: self.$subwooferDraft, in: 0...12, step: 1)
                            Button("Apply Subwoofer") { Task { await self.vm.setSubwoofer(Int(self.subwooferDraft)) } }
                        }
                        VStack(alignment: .leading) {
                            Text("Rear: \(Int(self.rearDraft))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: self.$rearDraft, in: 0...12, step: 1)
                            Button("Apply Rear") { Task { await self.vm.setRear(Int(self.rearDraft)) } }
                        }
                    }
                    Text("CEC state: output \(self.vm.cecState?.audioOutput.rawValue ?? "unknown"), mode \(self.vm.cecState?.soundMode?.rawValue ?? "unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connection")
                        .font(.headline)
                    formRow("SmartTube host") { TextField("127.0.0.1 or TV IP", text: self.$vm.host).textFieldStyle(.roundedBorder) }
                    formRow("SmartTube port") { TextField("8497", text: self.$vm.apiPort).textFieldStyle(.roundedBorder) }
                    formRow("ADB bridge host") { TextField("127.0.0.1", text: self.$vm.bridgeHost).textFieldStyle(.roundedBorder) }
                    formRow("ADB bridge port") { TextField("8498", text: self.$vm.bridgePort).textFieldStyle(.roundedBorder) }
                    formRow("ADB TV IP optional") { TextField("192.168.1.44", text: self.$vm.adbTVHost).textFieldStyle(.roundedBorder) }
                    formRow("Subnet prefix") { TextField("192.168.1", text: self.$vm.subnetPrefix).textFieldStyle(.roundedBorder) }
                    HStack {
                        Button("Save") { self.vm.saveSettings() }
                        Button("Auto Connect") { Task { await self.vm.autoConnect() } }
                        Button("Manual Connect") { Task { await self.vm.manualConnect() } }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pairing")
                        .font(.headline)
                    Text("TV code: \(self.vm.pairCodeFromTV.isEmpty ? "not loaded" : self.vm.pairCodeFromTV)")
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("6 digit pairing code", text: self.$vm.pairCodeInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Get Code") { Task { await self.vm.getPairCode() } }
                        Button("Pair") { Task { await self.vm.manualPair() } }
                    }
                    HStack {
                        Text("Token: \(self.vm.tokenRedacted)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget Token") { self.vm.forgetToken() }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Diagnostics")
                            .font(.headline)
                        Spacer()
                        Button("Copy Full Log") { self.vm.copyLogsToClipboard() }
                    }
                    TextEditor(text: .constant(self.vm.diagnosticsText))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 220)
                }
            }
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            content()
        }
    }
}

private struct TrackRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let selected: Bool
}

private struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct StatusPill: View {
    let text: String
    let active: Bool
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14)))
            .foregroundStyle(active ? .green : .secondary)
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

echo "Replaced $CV with clean macOS UI"
echo "Done. Rebuild in Xcode. If macOS sandbox is enabled, allow Outgoing Connections (Client)."

