#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
CONTENT="SmartTubecontroller/ContentView.swift"
SDK="SmartTubecontroller/SmartTubeSDK.swift"

if [ ! -f "$CONTENT" ]; then
  CONTENT="SmartTubecontroller/SmartTubecontroller/ContentView.swift"
fi
if [ ! -f "$SDK" ]; then
  SDK="SmartTubecontroller/SmartTubecontroller/SmartTubeSDK.swift"
fi

if [ ! -f "$CONTENT" ]; then
  echo "ContentView.swift not found. Run this from the Xcode project root."
  exit 1
fi

cp "$CONTENT" "$CONTENT.bak.$(date +%s)"

# Patch the SDK only where previous fix scripts may have left compile/runtime breakage.
if [ -f "$SDK" ]; then
  cp "$SDK" "$SDK.bak.$(date +%s)"
  python3 - "$SDK" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()

# Revert missing helper issue from earlier scripts: keep next/previous simple if commandWithRetry was inserted badly.
s = s.replace('commandWithRetry(', 'command(')

# WebSocket send is synchronous in the generated SDK.
s = s.replace('try await send(action:', 'try send(action:')
s = s.replace('await send(action:', 'send(action:')

# No-body POST requests must not send {}; avoid NanoHTTPD keep-alive poisoning.
if 'forHTTPHeaderField: "Connection"' not in s:
    s = s.replace('request.setValue("application/json", forHTTPHeaderField: "Content-Type")',
                  'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n        request.setValue("close", forHTTPHeaderField: "Connection")')

# Fix async nil-coalescing from earlier fallback patches if present.
s = s.replace(
'            let current = (try? await getTheaterVolume().volume) ?? (try? await getTheater().volume) ?? target',
'''            let volumeState = try? await getTheaterVolume()\n            let theaterState = volumeState == nil ? (try? await getTheater()) : nil\n            let current = volumeState?.volume ?? theaterState?.volume ?? target''')
s = s.replace(
'            let current = (try? await getTheaterVolume())?.volume ?? (try? await getTheater())?.volume ?? target',
'''            let volumeState = try? await getTheaterVolume()\n            let theaterState = volumeState == nil ? (try? await getTheater()) : nil\n            let current = volumeState?.volume ?? theaterState?.volume ?? target''')

# If a function now contains await, make its signature async and update direct call sites.
lines = s.splitlines()
for i, line in enumerate(lines):
    if 'await getTheaterVolume()' in line or 'await getTheater()' in line:
        for j in range(i, max(-1, i - 120), -1):
            if re.search(r'\bfunc\b', lines[j]):
                if ' async ' not in lines[j] and not lines[j].rstrip().endswith(' async'):
                    lines[j] = lines[j].replace(' throws ->', ' async throws ->')
                    lines[j] = lines[j].replace(' throws {', ' async throws {')
                    lines[j] = lines[j].replace(' throws\n', ' async throws\n')
                    lines[j] = lines[j].replace(' ->', ' async ->') if ' throws' not in lines[j] else lines[j]
                break
s = '\n'.join(lines) + '\n'
s = s.replace('try setTheaterVolumeWithFallback', 'try await setTheaterVolumeWithFallback')
s = s.replace('try await await', 'try await')

while 'self.self.' in s:
    s = s.replace('self.self.', 'self.')

p.write_text(s)
print('Patched SDK safety fixes:', p)
PY
fi

cat > "$CONTENT" <<'SWIFT'
//
//  ContentView.swift
//  SmartTubecontroller
//
//  Single-surface macOS controller UI for SmartTube.
//  Apple-style player surface + Up Next + Inspector.
//

import SwiftUI
import Combine
import AppKit

private enum InspectorSection: String, CaseIterable, Identifiable {
    case tracks = "Tracks"
    case theater = "Theater"
    case diagnostics = "Logs"
    var id: String { rawValue }
}

private struct FormatChoice: Identifiable, Hashable {
    let id: String
    let formatId: String
    let title: String
    let detail: String
    let isSelected: Bool
}

@MainActor
final class SmartTubeControllerViewModel: ObservableObject {
    @Published var apiHost: String = UserDefaults.standard.string(forKey: "st.apiHost") ?? "127.0.0.1"
    @Published var apiPort: String = UserDefaults.standard.string(forKey: "st.apiPort") ?? "8497"
    @Published var bridgeHost: String = UserDefaults.standard.string(forKey: "st.bridgeHost") ?? "localhost"
    @Published var bridgePort: String = UserDefaults.standard.string(forKey: "st.bridgePort") ?? "8498"
    @Published var token: String = UserDefaults.standard.string(forKey: "st.token") ?? ""
    @Published var pairInput: String = ""
    @Published var pendingPairCode: String = ""

    @Published var isAPIConnected = false
    @Published var isBridgeConnected = false
    @Published var isRealtimeConnected = false
    @Published var isPollingFallback = false
    @Published var isBusy = false
    @Published var phase = "Not connected"
    @Published var lastError: String?
    @Published var logs: [String] = []

    @Published var player: PlayerState?
    @Published var queue: [QueueItem] = []
    @Published var suggestions: [SuggestionItem] = []
    @Published var theater: TheaterState?
    @Published var cec: SmartTubeCECState?

    @Published var videoFormats: [FormatChoice] = []
    @Published var audioFormats: [FormatChoice] = []
    @Published var subtitleFormats: [FormatChoice] = []
    @Published var selectedVideoFormat: String?
    @Published var selectedAudioFormat: String?
    @Published var selectedSubtitleFormat: String?

    @Published var videoText = ""
    @Published var searchText = ""
    @Published var tvVolumeDraft: Double = 45
    @Published var appVolumeDraft: Double = 0.85
    @Published var speedDraft: Double = 1.0
    @Published var subwooferLevel: Double = 8
    @Published var rearLevel: Double = 8
    @Published var immersiveAE = false
    @Published var soundMode: SmartTubeSoundMode = .cinema

    private var client: SmartTubeClient?
    private var bridge: SmartTubeADBBridgeClient?
    private var ws: SmartTubeWebSocketClient?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var currentVideo: VideoInfo? { player?.video }
    var durationMs: Int { player?.durationMs ?? currentVideo?.durationMs ?? 0 }
    var positionMs: Int { player?.positionMs ?? 0 }
    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }
    var isPlaying: Bool { player?.state == .playing }
    var connectionSummary: String {
        if isRealtimeConnected { return "Live" }
        if isPollingFallback { return "Polling" }
        if isAPIConnected { return "Connected" }
        return "Offline"
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
        ws?.disconnect()
        bridge?.disconnect()
    }

    func boot() async {
        guard client == nil && bridge == nil else { return }
        await autoConnect()
    }

    func autoConnect() async {
        isBusy = true
        lastError = nil
        log("Starting auto-connect")
        defer { isBusy = false }

        await connectBridgeQuietly()

        if isBridgeConnected, let bridge {
            do {
                let info = try await bridge.smartTubeAutoconnect()
                apiHost = info.host
                apiPort = String(info.port)
                saveConnectionDefaults()
                log("ADB forwarded SmartTube from \(info.model.isEmpty ? info.serial : info.model) to \(info.host):\(info.port)")
            } catch {
                log("ADB autoconnect skipped: \(error.localizedDescription)")
            }
        }

        do {
            try await connectAPI(pairIfNeeded: true)
            await refreshEverything()
            startRealtime()
        } catch {
            fail("Auto-connect failed: \(error.localizedDescription)")
        }
    }

    func connectManually() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await connectAPI(pairIfNeeded: false)
            await refreshEverything()
            startRealtime()
        } catch {
            fail("Manual connect failed: \(error.localizedDescription)")
        }
    }

    func pairManually() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let c = try requireClient()
            let normalized = normalizedPairCode(pairInput)
            let result = try await c.verifyPairCode(normalized)
            token = result.token
            UserDefaults.standard.set(result.token, forKey: "st.token")
            log("Paired with \(result.deviceName)")
            try await connectAPI(pairIfNeeded: false)
            await refreshEverything()
            startRealtime()
        } catch {
            fail("Pairing failed: \(error.localizedDescription)")
        }
    }

    func fetchPairCode() async {
        do {
            let c = try requireClient()
            let pair = try await c.getPairCode()
            pendingPairCode = pair.code
            pairInput = pair.code
            log("Pair code fetched: \(pair.code)")
        } catch {
            fail("Fetch pair code failed: \(error.localizedDescription)")
        }
    }

    private func connectBridgeQuietly() async {
        do {
            let port = Int(bridgePort) ?? 8498
            let b = try SmartTubeADBBridgeClient(host: bridgeHost, port: port)
            b.connect()
            _ = try await b.ping()
            bridge = b
            isBridgeConnected = true
            log("ADB bridge connected at ws://\(bridgeHost):\(port)")
        } catch {
            isBridgeConnected = false
            log("ADB bridge unavailable: \(error.localizedDescription)")
        }
    }

    private func connectAPI(pairIfNeeded: Bool) async throws {
        let port = Int(apiPort) ?? 8497
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = SmartTubeClient(config: SmartTubeConfig(host: apiHost, port: port, token: trimmedToken.isEmpty ? nil : trimmedToken))
        client = c
        let ping = try await c.ping()
        isAPIConnected = true
        phase = "Connected to \(ping.deviceName)"
        log("Ping OK: \(ping.deviceName)")

        if trimmedToken.isEmpty && pairIfNeeded {
            do {
                let code = try await c.getPairCode().code
                pendingPairCode = code
                let verified = try await c.verifyPairCode(normalizedPairCode(code))
                token = verified.token
                UserDefaults.standard.set(verified.token, forKey: "st.token")
                log("Auto-paired with code from SmartTube")
            } catch {
                pendingPairCode = pendingPairCode.isEmpty ? "Fetch code and pair manually" : pendingPairCode
                throw error
            }
        }

        saveConnectionDefaults()
    }

    func refreshEverything() async {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshPlayerQueueTheater()
            await self.refreshFormats()
            await self.refreshSuggestions()
            await self.refreshCEC()
        }
    }

    func refreshPlayerQueueTheater() async {
        guard let c = client else { return }
        do {
            player = try await c.getPlayer()
            if let p = player {
                appVolumeDraft = p.volume ?? appVolumeDraft
                speedDraft = p.speed ?? speedDraft
            }
        } catch { log("Player refresh failed: \(error.localizedDescription)") }

        do { queue = try await c.getQueue() }
        catch { log("Queue refresh failed: \(error.localizedDescription)") }

        do {
            theater = try await c.getTheater()
            if let theater { tvVolumeDraft = Double(theater.volume) }
        } catch { log("Theater refresh failed: \(error.localizedDescription)") }
    }

    func refreshSuggestions() async {
        guard let c = client else { return }
        do { suggestions = try await c.getSuggestions() }
        catch { log("Suggestions refresh failed: \(error.localizedDescription)") }
    }

    func refreshFormats() async {
        guard let c = client else { return }
        async let vf = loadFormatChoices(c, path: "/api/player/formats/video", kind: "video")
        async let af = loadFormatChoices(c, path: "/api/player/formats/audio", kind: "audio")
        async let sf = loadFormatChoices(c, path: "/api/player/formats/subtitle", kind: "subtitle")
        videoFormats = await vf
        audioFormats = await af
        subtitleFormats = await sf
        selectedVideoFormat = videoFormats.first(where: { $0.isSelected })?.formatId ?? selectedVideoFormat
        selectedAudioFormat = audioFormats.first(where: { $0.isSelected })?.formatId ?? selectedAudioFormat
        selectedSubtitleFormat = subtitleFormats.first(where: { $0.isSelected })?.formatId ?? selectedSubtitleFormat
    }

    private func loadFormatChoices(_ c: SmartTubeClient, path: String, kind: String) async -> [FormatChoice] {
        do {
            let json = try await c.rawJSON(method: "GET", path: path)
            guard case .array(let items) = json else { return [] }
            return items.enumerated().compactMap { index, value in
                guard case .object(let obj) = value else { return nil }
                let formatId = obj.string("format_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !formatId.isEmpty else { return nil }
                let label = obj.string("label") ?? obj.string("language_label") ?? obj.string("language") ?? formatId
                let codec = obj.string("codec") ?? ""
                let bitrate = obj.int("bitrate")
                let detail: String
                if kind == "video" {
                    let size = [obj.int("width"), obj.int("height")].compactMap { $0 }.filter { $0 > 0 }
                    detail = [size.count == 2 ? "\(size[0])×\(size[1])" : nil, codec.isEmpty ? nil : codec, bitrate.map { "\($0 / 1000) kbps" }].compactMap { $0 }.joined(separator: " · ")
                } else {
                    detail = [codec.isEmpty ? nil : codec, bitrate.map { "\($0 / 1000) kbps" }].compactMap { $0 }.joined(separator: " · ")
                }
                return FormatChoice(id: "\(kind)-\(index)-\(formatId)", formatId: formatId, title: label, detail: detail, isSelected: obj.bool("is_selected") ?? false)
            }
        } catch {
            log("\(kind.capitalized) formats failed: \(error.localizedDescription)")
            return []
        }
    }

    func refreshCEC() async {
        guard let bridge else { return }
        do {
            let state = try await bridge.getParsedCECState()
            cec = sanitizedCEC(state)
            if let cec {
                subwooferLevel = Double(cec.subwooferLevel ?? Int(subwooferLevel))
                rearLevel = Double(cec.rearLevel ?? Int(rearLevel))
                immersiveAE = cec.immersiveAEEnabled ?? immersiveAE
                soundMode = cec.soundMode ?? soundMode
            }
        } catch {
            log("CEC refresh failed: \(error.localizedDescription)")
        }
    }

    private func startRealtime() {
        ws?.disconnect()
        isRealtimeConnected = false
        isPollingFallback = false
        pollingTask?.cancel()

        guard let c = client else { return }
        Task {
            let tokenValue = await c.config.token ?? token
            let hostValue = await c.config.host
            let portValue = await c.config.port
            guard !tokenValue.isEmpty else { return }
            let socket = SmartTubeWebSocketClient(
                config: SmartTubeConfig(host: hostValue, port: portValue, token: tokenValue),
                onEvent: { [weak self] event in
                    Task { @MainActor in self?.handleRealtime(event) }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.log("Realtime warning: \(error.localizedDescription)")
                    }
                },
                onClose: { [weak self] in
                    Task { @MainActor in
                        self?.isRealtimeConnected = false
                        self?.log("Realtime closed; polling fallback active")
                        self?.startPollingFallback()
                    }
                }
            )
            do {
                try socket.connect()
                self.ws = socket
                self.isRealtimeConnected = true
                self.phase = "Live updates connected"
                self.log("Realtime connected")
            } catch {
                self.log("Realtime unavailable: \(error.localizedDescription)")
                self.startPollingFallback()
            }
        }
    }

    private func handleRealtime(_ event: SmartTubeWebSocketEvent) {
        switch event {
        case .hello(_, let name):
            isRealtimeConnected = true
            phase = name.map { "Live with \($0)" } ?? "Live updates connected"
        case .stateUpdate(let state):
            player = state
            if let volume = state.volume { appVolumeDraft = volume }
            if let speed = state.speed { speedDraft = speed }
        case .json:
            break
        }
    }

    private func startPollingFallback() {
        guard !isPollingFallback else { return }
        pollingTask?.cancel()
        isPollingFallback = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPlayerQueueTheater()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func togglePlayback() async { await run("Play/Pause") { try await requireClient().toggle(); await refreshPlayerQueueTheater() } }
    func play() async { await run("Play") { try await requireClient().play(); await refreshPlayerQueueTheater() } }
    func pause() async { await run("Pause") { try await requireClient().pause(); await refreshPlayerQueueTheater() } }
    func stop() async { await run("Stop") { try await requireClient().stop(); await refreshPlayerQueueTheater() } }
    func next() async { await run("Next") { try await requireClient().next(); await refreshPlayerQueueTheater() } }
    func previous() async { await run("Previous") { try await requireClient().previous(); await refreshPlayerQueueTheater() } }

    func seekToProgress(_ progress: Double) async {
        let target = Int(Double(durationMs) * min(max(progress, 0), 1))
        await run("Seek") { _ = try await requireClient().seek(positionMs: target); await refreshPlayerQueueTheater() }
    }

    func jump(seconds: Int) async {
        let target = min(max(positionMs + seconds * 1000, 0), max(durationMs, 0))
        await run("Jump \(seconds)s") { _ = try await requireClient().seek(positionMs: target); await refreshPlayerQueueTheater() }
    }

    func setAppVolume(_ value: Double) async {
        appVolumeDraft = value
        await run("Set app volume") { _ = try await requireClient().setVolume(value); await refreshPlayerQueueTheater() }
    }

    func setSpeed(_ value: Double) async {
        speedDraft = value
        await run("Set speed") { _ = try await requireClient().setSpeed(value); await refreshPlayerQueueTheater() }
    }

    func setTVVolumeNearest(_ targetDouble: Double) async {
        let target = min(max(Int(targetDouble.rounded()), 0), 100)
        await run("Set TV volume") {
            let c = try requireClient()
            let current = (try? await c.getTheaterVolume().volume) ?? theater?.volume ?? target
            let diff = target - current
            if diff > 0 {
                for _ in 0..<min(diff, 30) { _ = try await c.theaterVolumeUp() }
            } else if diff < 0 {
                for _ in 0..<min(abs(diff), 30) { _ = try await c.theaterVolumeDown() }
            }
            await refreshPlayerQueueTheater()
        }
    }

    func tvVolumeStep(_ delta: Int) async {
        await run(delta > 0 ? "TV volume up" : "TV volume down") {
            if delta > 0 { _ = try await requireClient().theaterVolumeUp() } else { _ = try await requireClient().theaterVolumeDown() }
            await refreshPlayerQueueTheater()
        }
    }

    func sendVideo(playNow: Bool) async {
        let text = videoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await run(playNow ? "Open video" : "Add to queue") {
            let c = try requireClient()
            if playNow {
                if text.lowercased().hasPrefix("http") { _ = try await c.openURL(text) }
                else { _ = try await c.openVideoId(text) }
            } else if let id = extractVideoId(text) {
                _ = try await c.addToQueue(videoId: id)
            } else {
                throw SimpleUIError("Add to queue needs a YouTube URL or video id")
            }
            videoText = ""
            await refreshEverything()
        }
    }

    func searchAndPlay() async {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await run("Search and play") { _ = try await requireClient().searchAndPlay(text); await refreshEverything() }
    }

    func queuePlayNext(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await run("Play next") { _ = try await requireClient().playNext(videoId: id); await refreshEverything() }
    }

    func queueRemove(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await run("Remove from queue") { _ = try await requireClient().removeFromQueue(videoId: id); await refreshEverything() }
    }

    func clearQueue() async { await run("Clear queue") { _ = try await requireClient().clearQueue(); await refreshEverything() } }

    func applyVideoFormat() async {
        guard let id = selectedVideoFormat else { return }
        await run("Set quality") { _ = try await requireClient().setVideoFormat(id); await refreshFormats() }
    }
    func applyAudioFormat() async {
        guard let id = selectedAudioFormat else { return }
        await run("Set audio") { _ = try await requireClient().setAudioFormat(id); await refreshFormats() }
    }
    func applySubtitleFormat() async {
        await run("Set subtitles") { _ = try await requireClient().setSubtitleFormat(selectedSubtitleFormat); await refreshFormats() }
    }
    func disableSubtitles() async { await run("Disable subtitles") { _ = try await requireClient().setSubtitleFormat(nil); await refreshFormats() } }

    func setHomeTheater() async { await run("Home theater speakers") { _ = try await requireBridge().setHomeTheaterSpeakers(); await refreshCEC() } }
    func setTVSpeakers() async { await run("TV speakers") { _ = try await requireBridge().setTVSpeakers(); await refreshCEC() } }
    func setSubwoofer() async { await run("Set subwoofer") { _ = try await requireBridge().setSubwooferLevel(Int(subwooferLevel)); await refreshCEC() } }
    func setRear() async { await run("Set rear level") { _ = try await requireBridge().setRearLevel(Int(rearLevel)); await refreshCEC() } }
    func setImmersive(_ enabled: Bool) async { immersiveAE = enabled; await run("Immersive AE") { _ = try await requireBridge().setImmersiveAE(enabled); await refreshCEC() } }
    func setSoundMode() async { await run("Sound mode") { _ = try await requireBridge().setSoundMode(soundMode); await refreshCEC() } }
    func powerToggle() async { await run("Power toggle") { _ = try await requireBridge().powerToggle(); await refreshCEC() } }

    private func run(_ title: String, _ block: @escaping () async throws -> Void) async {
        isBusy = true
        phase = "\(title)…"
        log("\(title)…")
        defer { isBusy = false }
        do {
            try await block()
            phase = "\(title) OK"
            log("\(title) OK")
        } catch {
            fail("\(title) failed: \(error.localizedDescription)")
        }
    }

    func copyDiagnostics() {
        let text = diagnosticsText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("Copied diagnostics")
    }

    func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
        log("Copied logs")
    }

    private func requireClient() throws -> SmartTubeClient {
        guard let client else { throw SimpleUIError("SmartTube API is not connected") }
        return client
    }

    private func requireBridge() throws -> SmartTubeADBBridgeClient {
        guard let bridge else { throw SimpleUIError("ADB bridge is not connected") }
        return bridge
    }

    private func normalizedPairCode(_ code: String) -> String {
        let digits = code.filter { $0.isNumber }
        if digits.count == 6 { return String(digits.prefix(3)) + " " + String(digits.suffix(3)) }
        return code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveConnectionDefaults() {
        UserDefaults.standard.set(apiHost, forKey: "st.apiHost")
        UserDefaults.standard.set(apiPort, forKey: "st.apiPort")
        UserDefaults.standard.set(bridgeHost, forKey: "st.bridgeHost")
        UserDefaults.standard.set(bridgePort, forKey: "st.bridgePort")
        if !token.isEmpty { UserDefaults.standard.set(token, forKey: "st.token") }
    }

    private func fail(_ message: String) {
        lastError = message
        phase = message
        log("Failed: \(message)")
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    private func diagnosticsText() -> String {
        """
        SmartTube controller diagnostics
        API: \(apiHost):\(apiPort)
        Bridge: \(bridgeHost):\(bridgePort)
        Token: \(token.isEmpty ? "none" : String(token.prefix(6)) + "…" + String(token.suffix(4)))
        Connected: api=\(isAPIConnected), realtime=\(isRealtimeConnected), polling=\(isPollingFallback), bridge=\(isBridgeConnected)
        Phase: \(phase)
        Player: \(player?.state.rawValue ?? "nil") pos=\(positionMs) dur=\(durationMs)
        Video: \(currentVideo?.title ?? "nil")
        Queue: \(queue.count) items; Suggestions: \(suggestions.count)
        Theater: volume=\(theater?.volume.description ?? "nil") muted=\(theater?.muted.description ?? "nil") output=\(theater?.audioOutput ?? "nil")
        CEC: output=\(cec?.audioOutput.rawValue ?? "nil") sub=\(cec?.subwooferLevel?.description ?? "nil") rear=\(cec?.rearLevel?.description ?? "nil") immersive=\(cec?.immersiveAEEnabled?.description ?? "nil") mode=\(cec?.soundMode?.rawValue ?? "nil")
        Last error: \(lastError ?? "none")

        Log:
        \(logs.joined(separator: "\n"))
        """
    }
}

struct ContentView: View {
    @StateObject private var vm = SmartTubeControllerViewModel()
    @State private var inspector: InspectorSection = .tracks
    @State private var seekDraft: Double = 0
    @State private var seeking = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.black.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                self.topToolbar
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 14) {
                        self.playerSurface
                        self.transportSurface
                        self.addAndSearchSurface
                    }
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)

                    Divider()

                    self.queueSurface
                        .frame(width: 330)

                    Divider()

                    self.inspectorSurface
                        .frame(width: 310)
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 720)
        .task { await self.vm.boot() }
    }

    private var topToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(self.statusColor)
                    .frame(width: 10, height: 10)
                Text(self.vm.connectionSummary)
                    .font(.headline)
                Text(self.vm.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            TextField("API host", text: self.$vm.apiHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            TextField("Port", text: self.$vm.apiPort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
            Button("Connect") { Task { await self.vm.connectManually() } }
            Button("Auto") { Task { await self.vm.autoConnect() } }
                .buttonStyle(.borderedProminent)

            Divider().frame(height: 20)

            Button("Copy Logs") { self.vm.copyLogs() }
            Button("Diagnostics") { self.vm.copyDiagnostics() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var playerSurface: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black)
                .overlay(self.thumbnailView.clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)))
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                )
                .shadow(radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(self.vm.player?.state.rawValue.capitalized ?? "Idle", systemImage: self.vm.isPlaying ? "play.fill" : "pause.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if let video = self.vm.currentVideo, video.isLive == true {
                        Text("LIVE")
                            .font(.caption.bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.red, in: Capsule())
                    }
                }

                Spacer()

                Text(self.vm.currentVideo?.title ?? "Nothing playing")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(self.vm.currentVideo?.author ?? "Connect to SmartTube and start playback")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 410)
        .onChange(of: self.vm.progress) { _, newValue in
            if !self.seeking { self.seekDraft = newValue }
        }
    }

    private var thumbnailView: some View {
        Group {
            if let value = self.vm.currentVideo?.thumbnailURL, let url = URL(string: value) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        self.placeholderArtwork
                    case .empty:
                        ZStack { self.placeholderArtwork; ProgressView().controlSize(.large) }
                    @unknown default:
                        self.placeholderArtwork
                    }
                }
            } else {
                self.placeholderArtwork
            }
        }
    }

    private var placeholderArtwork: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.45), .blue.opacity(0.35), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.tv.fill")
                .font(.system(size: 86, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var transportSurface: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text(self.timeString(self.vm.positionMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Slider(value: self.$seekDraft, in: 0...1, onEditingChanged: { editing in
                    self.seeking = editing
                    if !editing { Task { await self.vm.seekToProgress(self.seekDraft) } }
                })
                Text(self.timeString(self.vm.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Button { Task { await self.vm.previous() } } label: { Image(systemName: "backward.end.fill") }
                Button { Task { await self.vm.jump(seconds: -10) } } label: { Image(systemName: "gobackward.10") }
                Button { Task { await self.vm.togglePlayback() } } label: {
                    Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 52, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                Button { Task { await self.vm.jump(seconds: 10) } } label: { Image(systemName: "goforward.10") }
                Button { Task { await self.vm.next() } } label: { Image(systemName: "forward.end.fill") }

                Divider().frame(height: 28)

                Label("App", systemImage: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(value: self.$vm.appVolumeDraft, in: 0...1, onEditingChanged: { editing in
                    if !editing { Task { await self.vm.setAppVolume(self.vm.appVolumeDraft) } }
                })
                .frame(width: 120)

                Picker("Speed", selection: self.$vm.speedDraft) {
                    Text("0.75×").tag(0.75)
                    Text("1×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .frame(width: 96)
                Button("Apply") { Task { await self.vm.setSpeed(self.vm.speedDraft) } }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var addAndSearchSurface: some View {
        HStack(spacing: 12) {
            TextField("Paste YouTube URL or video ID", text: self.$vm.videoText)
                .textFieldStyle(.roundedBorder)
            Button("Play") { Task { await self.vm.sendVideo(playNow: true) } }
                .buttonStyle(.borderedProminent)
            Button("Queue") { Task { await self.vm.sendVideo(playNow: false) } }

            Divider().frame(height: 24)

            TextField("Search and play", text: self.$vm.searchText)
                .textFieldStyle(.roundedBorder)
            Button { Task { await self.vm.searchAndPlay() } } label: { Label("Search", systemImage: "magnifyingglass") }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var queueSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up Next")
                    .font(.title2.bold())
                Spacer()
                Button { Task { await self.vm.refreshEverything() } } label: { Image(systemName: "arrow.clockwise") }
                Button("Clear") { Task { await self.vm.clearQueue() } }
                    .disabled(self.vm.queue.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if self.vm.queue.isEmpty {
                ContentUnavailableView("Queue empty", systemImage: "list.bullet.rectangle", description: Text("Add a video or refresh SmartTube suggestions."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(self.vm.queue) { item in
                            self.queueRow(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }

            if !self.vm.suggestions.isEmpty {
                Divider()
                Text("Suggestions")
                    .font(.headline)
                    .padding(.horizontal, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(self.vm.suggestions.prefix(8)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title ?? item.videoId ?? "Suggestion")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text(item.author ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 150, alignment: .leading)
                            .padding(10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contextMenu {
                                Button("Play Next") { Task { await self.vm.queuePlayNext(item) } }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func queueRow(_ item: QueueItem) -> some View {
        HStack(spacing: 10) {
            Text(item.index.map { "\($0 + 1)" } ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.videoId ?? "Untitled")
                    .font(.subheadline.weight(item.isCurrent == true ? .bold : .regular))
                    .lineLimit(2)
                Text(item.author ?? (item.isCurrent == true ? "Now playing" : "Queued"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.isCurrent == true {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.blue)
            }
        }
        .padding(10)
        .background(item.isCurrent == true ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button("Play Next") { Task { await self.vm.queuePlayNext(item) } }
            Button("Remove") { Task { await self.vm.queueRemove(item) } }
        }
    }

    private var inspectorSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Inspector", selection: self.$inspector) {
                ForEach(InspectorSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch self.inspector {
                    case .tracks:
                        self.tracksInspector
                    case .theater:
                        self.theaterInspector
                    case .diagnostics:
                        self.logsInspector
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var tracksInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.sectionTitle("Quality", "switch.2")
            Picker("Video", selection: self.$vm.selectedVideoFormat) {
                Text("Auto / current").tag(Optional<String>.none)
                ForEach(self.vm.videoFormats) { row in Text(row.title).tag(Optional(row.formatId)) }
            }
            Button("Apply Quality") { Task { await self.vm.applyVideoFormat() } }
                .disabled(self.vm.selectedVideoFormat == nil)

            Divider()
            self.sectionTitle("Audio", "waveform")
            Picker("Audio", selection: self.$vm.selectedAudioFormat) {
                Text("Current").tag(Optional<String>.none)
                ForEach(self.vm.audioFormats) { row in Text(row.title).tag(Optional(row.formatId)) }
            }
            Button("Apply Audio") { Task { await self.vm.applyAudioFormat() } }
                .disabled(self.vm.selectedAudioFormat == nil)

            Divider()
            self.sectionTitle("Subtitles", "captions.bubble")
            Picker("Subtitle", selection: self.$vm.selectedSubtitleFormat) {
                Text("None").tag(Optional<String>.none)
                ForEach(self.vm.subtitleFormats.prefix(80)) { row in Text(row.title).tag(Optional(row.formatId)) }
            }
            HStack {
                Button("Apply") { Task { await self.vm.applySubtitleFormat() } }
                Button("Off") { Task { await self.vm.disableSubtitles() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var theaterInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            self.sectionTitle("TV Audio", "hifispeaker.2")
            HStack {
                Button("Theater") { Task { await self.vm.setHomeTheater() } }
                Button("TV") { Task { await self.vm.setTVSpeakers() } }
                Button { Task { await self.vm.powerToggle() } } label: { Image(systemName: "power") }
            }
            .buttonStyle(.bordered)

            HStack {
                Button { Task { await self.vm.tvVolumeStep(-1) } } label: { Image(systemName: "minus") }
                Slider(value: self.$vm.tvVolumeDraft, in: 0...100, onEditingChanged: { editing in
                    if !editing { Task { await self.vm.setTVVolumeNearest(self.vm.tvVolumeDraft) } }
                })
                Button { Task { await self.vm.tvVolumeStep(1) } } label: { Image(systemName: "plus") }
                Text("\(Int(self.vm.tvVolumeDraft))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28)
            }

            Text("Output: \(self.vm.theater?.audioOutput ?? self.vm.cec?.audioOutput.rawValue ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            self.sectionTitle("CEC Tuning", "slider.horizontal.3")
            LabeledContent("Subwoofer") {
                HStack {
                    Slider(value: self.$vm.subwooferLevel, in: 0...12, step: 1)
                    Text("\(Int(self.vm.subwooferLevel))")
                    Button("Set") { Task { await self.vm.setSubwoofer() } }
                }
            }
            LabeledContent("Rear") {
                HStack {
                    Slider(value: self.$vm.rearLevel, in: 0...12, step: 1)
                    Text("\(Int(self.vm.rearLevel))")
                    Button("Set") { Task { await self.vm.setRear() } }
                }
            }
            Toggle("Immersive AE", isOn: Binding(get: { self.vm.immersiveAE }, set: { enabled in Task { await self.vm.setImmersive(enabled) } }))
            Picker("Sound", selection: self.$vm.soundMode) {
                ForEach(SmartTubeSoundMode.allCases, id: \.rawValue) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            Button("Apply Sound Mode") { Task { await self.vm.setSoundMode() } }
            Button("Refresh CEC") { Task { await self.vm.refreshCEC() } }
        }
    }

    private var logsInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let err = self.vm.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack {
                Button("Copy Logs") { self.vm.copyLogs() }
                Button("Copy Diagnostics") { self.vm.copyDiagnostics() }
            }
            Text(self.vm.logs.suffix(80).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
    }

    private var statusColor: Color {
        if self.vm.isRealtimeConnected { return .green }
        if self.vm.isPollingFallback || self.vm.isAPIConnected { return .yellow }
        return .red
    }

    private func timeString(_ ms: Int) -> String {
        guard ms > 0 else { return "0:00" }
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct SimpleUIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard let value = self[key] else { return nil }
        if case .string(let s) = value { return s }
        if case .number(let n) = value { return String(Int(n)) }
        return nil
    }
    func int(_ key: String) -> Int? {
        guard let value = self[key] else { return nil }
        if case .number(let n) = value { return Int(n) }
        if case .string(let s) = value { return Int(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        guard let value = self[key] else { return nil }
        if case .bool(let b) = value { return b }
        return nil
    }
}

private func extractVideoId(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 8 && !trimmed.contains("/") && !trimmed.contains("?") { return trimmed }
    guard let url = URL(string: trimmed), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
    let parts = url.path.split(separator: "/").map(String.init)
    if let last = parts.last, !last.isEmpty { return last }
    return nil
}

private func sanitizedCEC(_ state: SmartTubeCECState) -> SmartTubeCECState {
    func clean(_ value: Int?) -> Int? {
        guard let value, value >= 0, value <= 12 else { return nil }
        return value
    }
    return SmartTubeCECState(
        audioOutput: state.audioOutput,
        subwooferLevel: clean(state.subwooferLevel),
        rearLevel: clean(state.rearLevel),
        immersiveAEEnabled: state.immersiveAEEnabled,
        soundMode: state.soundMode
    )
}

#Preview {
    ContentView()
}
SWIFT

echo "Replaced $CONTENT with unified Apple-style player UI."
echo "Backups were created next to modified files."
echo "Now run: Product -> Clean Build Folder, then build."

