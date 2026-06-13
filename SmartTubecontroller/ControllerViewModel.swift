//
//  ControllerViewModel.swift
//  SmartTubecontroller
//

import SwiftUI
import AppKit
import Combine

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

    @Published var player: PlayerState? {
        // Every state update (realtime WS + poll) carries the selected tracks —
        // apply them so quality/audio/subtitle pickers stay live without refetching.
        didSet { self.applySelectedTracks() }
    }
    @Published var queue: [QueueItem] = []
    @Published var suggestions: [QueueItem] = []
    @Published var recommended: [QueueItem] = []
    @Published var searchResults: [QueueItem] = []
    @Published var isSearching: Bool = false
    @Published var searchError: String?
    @Published var chapters: [ChapterItem] = []
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
        // Blank ADB host means "same as the API host"; ADB-over-network uses port 5555.
        self.bridgeHost = defaults.string(forKey: "smarttube.bridge.host") ?? ""
        self.bridgePort = defaults.string(forKey: "smarttube.bridge.port") ?? "5555"
        self.playerVolumeEnabled = defaults.bool(forKey: "smarttube.playervolume.enabled")
    }

    /// Optional secondary control for ExoPlayer's internal volume (normally 100%).
    @Published var playerVolumeEnabled: Bool = false {
        didSet { self.defaults.set(self.playerVolumeEnabled, forKey: "smarttube.playervolume.enabled") }
    }

    var playbackVolumePercent: Int { Int(((self.player?.volume ?? 1) * 100).rounded()) }

    var apiPortInt: Int { Int(self.apiPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8497 }
    var bridgePortInt: Int { Int(self.bridgePort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5555 }

    /// The ADB target host: an explicit override, or the API/TV host when left blank.
    var adbHost: String {
        let override = self.bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? self.host : override
    }

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

    /// YouTube's maxres thumbnail (1280×720). Not every video has one — callers must
    /// fall back to `thumbnailURL` on failure.
    var hiResThumbnailURL: URL? {
        guard let id = self.player?.video?.videoId, !id.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
    }

    var stateText: String { self.player?.state.rawValue.capitalized ?? "Idle" }
    var isPlaying: Bool { self.player?.state == .playing }
    var isBuffering: Bool { self.player?.state == .buffering }
    var positionMs: Int { self.player?.positionMs ?? 0 }
    var durationMs: Int { self.player?.durationMs ?? self.player?.video?.durationMs ?? 0 }

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
        let host = self.adbHost
        self.bridgePhase = "Connecting ADB…"
        // Keep the client around even when the first ping fails — it reconnects
        // lazily, so the next theater command retries instead of erroring with
        // "not connected" forever.
        let b = try? SmartTubeADBBridgeClient(host: host, port: self.bridgePortInt)
        self.bridge = b
        do {
            guard let b else { throw SmartTubeADBBridgeError.adbNotFound }
            b.connect()
            _ = try await b.ping()
            self.isBridgeConnected = true
            self.bridgePhase = "ADB connected"
            self.log("ADB connected to \(host):\(self.bridgePortInt)")
        } catch {
            self.isBridgeConnected = false
            self.bridgePhase = "ADB unavailable — will retry on use"
            self.log("ADB unavailable: \(error.localizedDescription)")
        }
    }

    func connectAPIAndPairIfNeeded() async {
        self.saveSettings()
        let plainClient = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt))

        var pairingRequired = true
        do {
            let ping = try await plainClient.ping()
            pairingRequired = ping.pairingRequired ?? true
            self.phase = "Ping OK: \(ping.deviceName)"
            self.log("Ping OK: \(ping.deviceName)\(pairingRequired ? "" : " (open mode)")")
        } catch {
            self.isAPIConnected = false
            self.phase = "API connection failed"
            self.lastError = error.localizedDescription
            self.log("API connection failed: \(error.localizedDescription)")
            return
        }

        let savedToken = self.token.trimmingCharacters(in: .whitespacesAndNewlines)

        // Open mode: the TV accepts any local connection — connect directly, no pairing.
        // A non-empty placeholder token keeps the auth header/WS query populated; the
        // server ignores it in open mode.
        if !pairingRequired {
            let openToken = savedToken.isEmpty ? "open" : savedToken
            if let authed = await self.probeToken(openToken, failureLog: "Open-mode connect failed, falling back") {
                self.token = openToken
                await self.adopt(client: authed, phase: "Connected", log: "Connected (open mode, no pairing)", save: true)
                return
            }
        }

        if !savedToken.isEmpty {
            if let authed = await self.probeToken(savedToken, failureLog: "Saved token rejected") {
                await self.adopt(client: authed, phase: "Connected", log: "Saved token accepted", save: false)
                return
            }
        }

        do {
            self.phase = "Pairing automatically…"
            let pair = try await plainClient.getPairCode()
            let verified = try await self.verifyPairCodeRobust(client: plainClient, code: pair.code)
            self.token = verified.token
            let authed = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: verified.token))
            await self.adopt(client: authed, phase: "Paired with \(verified.deviceName)", log: "Auto pair OK", save: true)
        } catch {
            self.isAPIConnected = false
            self.phase = "Pairing failed"
            self.lastError = "Pairing failed: \(error.localizedDescription)"
            self.log(self.lastError ?? "Pairing failed")
        }
    }

    /// Probes a token by building an authed client and hitting the queue endpoint
    /// (which works even when the player is idle — /api/player returns 503 with no
    /// video loaded, which is NOT an auth failure). Returns the client on success.
    private func probeToken(_ token: String, failureLog: String) async -> SmartTubeClient? {
        let authed = SmartTubeClient(config: SmartTubeConfig(host: self.host, port: self.apiPortInt, token: token))
        do {
            _ = try await authed.getQueue()
            return authed
        } catch {
            self.log("\(failureLog): \(error.localizedDescription)")
            return nil
        }
    }

    /// Adopts a verified client as the active connection and kicks off the
    /// post-connect refresh/realtime/poll sequence.
    private func adopt(client: SmartTubeClient, phase: String, log message: String, save: Bool) async {
        self.client = client
        self.isAPIConnected = true
        self.phase = phase
        self.log(message)
        if save { self.saveSettings() }
        await self.afterConnected()
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

        await self.logged("Player refresh") {
            self.player = try await c.getPlayer()
            self.log("Player refreshed: \(self.player?.state.rawValue ?? "unknown")")
        }
        await self.logged("Queue refresh") {
            self.queue = Self.stableOrderMerge(old: self.queue, new: try await c.getQueue())
            self.log("Queue refreshed: \(self.queue.count) items")
        }
        await self.logged("Theater refresh") {
            self.theater = try await c.getTheater()
            self.log("Theater refreshed: volume \(self.theater?.volume ?? 0)")
        }

        await self.refreshTracks()
        await self.refreshCEC()
        await self.refreshSuggestions()
        await self.refreshRecommended()
        await self.refreshChapters()
    }

    /// Chapters of the current video. Quiet on failure — older servers don't have
    /// the endpoint, and the UI simply hides chapter affordances when empty.
    func refreshChapters() async {
        guard let c = self.client else { return }
        do {
            self.chapters = try await c.getChapters().sorted { $0.startMs < $1.startMs }
        } catch {
            self.chapters = []
        }
    }

    /// The chapter the playhead is currently inside, if the video has chapters.
    var currentChapter: ChapterItem? {
        self.chapters.last(where: { $0.startMs <= self.positionMs })
    }

    /// Runs a refresh body, logging `"<label> failed: …"` on throw. The body is
    /// responsible for its own success log so per-refresh success messages stay intact.
    private func logged(_ label: String, _ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
        } catch {
            self.log("\(label) failed: \(error.localizedDescription)")
        }
    }

    private var lastPollError: String?
    private var lastVideoId: String?

    func refreshFast() async {
        guard let c = self.client else { return }
        do {
            self.player = try await c.getPlayer()
            if self.lastPollError != nil {
                self.lastPollError = nil
                self.log("Player poll recovered")
            }
            // The TV's suggestion list belongs to the CURRENT video — refresh ours when
            // it changes, or clicking a recommendation plays a stale/wrong entry.
            let videoId = self.player?.video?.videoId
            if videoId != self.lastVideoId {
                self.lastVideoId = videoId
                await self.refreshSuggestions(replace: true)
                await self.refreshTracks()
                await self.refreshChapters()
            }
        } catch {
            // Log once per distinct error so decode/transport failures are visible
            // without spamming every 2s poll.
            let message = error.localizedDescription
            if message != self.lastPollError {
                self.lastPollError = message
                self.log("Player poll failed: \(message)")
            }
        }
        do { self.queue = Self.stableOrderMerge(old: self.queue, new: try await c.getQueue()) } catch { }
        do { self.theater = try await c.getTheater() } catch { }
    }

    /// Re-applies the previous on-screen order to a freshly fetched list. SmartTube's
    /// Playlist moves replayed videos to the end and the recommended feed reshuffles
    /// on every fetch, so a raw replacement makes rows jump around under the 2s poll.
    /// Items keep their old position (with refreshed data, e.g. is_current); genuinely
    /// new items append in server order; vanished items drop out.
    static func stableOrderMerge(old: [QueueItem], new: [QueueItem]) -> [QueueItem] {
        guard !old.isEmpty, !new.isEmpty else { return new }
        var fresh: [String: QueueItem] = [:]
        for item in new {
            guard let id = item.videoId else { continue }
            // keep the first occurrence if the server ever sends duplicates
            if fresh[id] == nil { fresh[id] = item }
        }
        var merged: [QueueItem] = []
        for item in old {
            guard let id = item.videoId, let updated = fresh.removeValue(forKey: id) else { continue }
            merged.append(updated)
        }
        for item in new {
            if let id = item.videoId {
                guard let remaining = fresh.removeValue(forKey: id) else { continue }
                merged.append(remaining)
            } else {
                // no videoId to match on — keep it rather than silently dropping it
                merged.append(item)
            }
        }
        return merged
    }

    func refreshTracks() async {
        guard let c = self.client else { return }
        await self.logged("Tracks refresh") {
            self.videoFormats = try await self.loadFormats(client: c, path: "/api/player/formats/video", kind: .video)
            self.audioFormats = try await self.loadFormats(client: c, path: "/api/player/formats/audio", kind: .audio)
            self.subtitleFormats = try await self.loadFormats(client: c, path: "/api/player/formats/subtitle", kind: .subtitle)
            self.log("Tracks refreshed")
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

    private func applySelectedTracks() {
        guard let selected = self.player?.selectedTracks else { return }

        func mark(_ list: [RemoteFormat], id: String?) -> [RemoteFormat] {
            guard let id, !id.isEmpty, list.contains(where: { $0.id == id }) else { return list }
            guard list.first(where: { $0.selected })?.id != id else { return list } // already current
            return list.map {
                RemoteFormat(id: $0.id, kind: $0.kind, title: $0.title, subtitle: $0.subtitle, selected: $0.id == id)
            }
        }

        self.videoFormats = mark(self.videoFormats, id: selected.video?.formatId)
        self.audioFormats = mark(self.audioFormats, id: selected.audio?.formatId)
        self.subtitleFormats = mark(self.subtitleFormats, id: selected.subtitle?.formatId)
    }

    func refreshCEC() async {
        guard let b = self.bridge else { return }
        await self.logged("CEC refresh") {
            let parsed = try await b.getParsedCECState()
            self.cec = Self.cleanCEC(parsed)
            // A successful CEC read proves the lazy ADB connection is up.
            if !self.isBridgeConnected {
                self.isBridgeConnected = true
                self.bridgePhase = "ADB connected"
            }
            self.log("CEC refreshed")
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
                    let oldVideoId = self.player?.video?.videoId
                    self.player = state
                    self.isRealtimeConnected = true
                    let newVideoId = state.video?.videoId
                    if newVideoId != oldVideoId {
                        self.lastVideoId = newVideoId
                        await self.refreshSuggestions(replace: true)
                        await self.refreshTracks()
                        await self.refreshChapters()
                    }
                case .json(let json):
                    self.log("Realtime JSON: \(String(describing: json))")
                }
            }
        }
        socket.onError = { [weak self] error in
            guard let controller = self else { return }
            Task { @MainActor [controller] in
                controller.isRealtimeConnected = false
                controller.log("Realtime warning: \(error.localizedDescription)")
            }
        }
        socket.onClose = { [weak self, weak socket] in
            Task { @MainActor in
                guard let self else { return }
                self.isRealtimeConnected = false
                // Only auto-reconnect if this socket is still the active one
                // (a manual reconnect replaces self.realtime first).
                guard self.realtime === socket else { return }
                self.log("Realtime closed; reconnecting in 3s (polling continues)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.isAPIConnected && !self.isRealtimeConnected && self.realtime === socket {
                    self.connectRealtime()
                }
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

    /// Sets ExoPlayer's internal volume (0–100). Hidden behind the
    /// "player volume" setting — it's a pre-amp gain, secondary to TV volume.
    func setPlaybackVolume(percent: Int) async {
        let value = min(max(Double(percent) / 100.0, 0), 1)
        await self.run("Set player volume") {
            try await self.clientOrThrow().setVolume(value)
        }
    }

    /// Sets the TV / audio-system volume (0–100) — the primary volume control.
    func setTVVolume(percent: Int) async {
        await self.run("Set TV volume") {
            try await self.clientOrThrow().setTheaterVolume(percent)
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

    /// Fetches search results for the picker without touching playback. Quiet on
    /// failure (no isBusy/phase churn) — this runs on every keystroke debounce.
    func search(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let c = self.client else {
            self.searchResults = []
            self.searchError = nil
            return
        }
        self.isSearching = true
        self.searchError = nil
        self.searchResults = []
        defer { self.isSearching = false }
        do {
            self.searchResults = try await c.searchResults(text)
        } catch is CancellationError {
            // superseded by a newer keystroke
        } catch {
            let message = error.localizedDescription
            self.searchError = message
            self.log("Search failed: \(message)")
            self.searchResults = []
        }
    }

    func clearSearchResults() {
        self.searchResults = []
        self.searchError = nil
    }

    func playVideoId(_ videoId: String) async {
        await self.run("Play video") {
            try await self.clientOrThrow().openVideoId(videoId)
        }
    }

    func playSearchResult(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await self.playVideoId(id)
        await self.refreshFast()
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

    /// `replace: true` swaps the list wholesale — used when the playing video changes
    /// and the related list belongs to a new video. Default keeps on-screen order stable.
    func refreshSuggestions(replace: Bool = false) async {
        guard let c = self.client else { return }
        await self.logged("Suggestions refresh") {
            let fetched = try await c.getSuggestions()
            self.suggestions = replace ? fetched : Self.stableOrderMerge(old: self.suggestions, new: fetched)
            self.log("Suggestions refreshed: \(self.suggestions.count)")
        }
    }

    // Play a related-videos suggestion. By video ID when we have one (immune to the
    // list refreshing under us); index is only the legacy fallback.
    func playSuggestion(_ item: QueueItem, at index: Int) async {
        await self.run("Play suggestion") {
            if let id = item.videoId, !id.isEmpty {
                try await self.clientOrThrow().playSuggestion(videoId: id)
            } else {
                try await self.clientOrThrow().playSuggestion(index: index)
            }
        }
        await self.refreshFast()
    }

    // The user's Home recommendations (server-side cached) — unlike `suggestions`,
    // which are the related videos of whatever is currently playing.
    func refreshRecommended() async {
        guard let c = self.client else { return }
        await self.logged("Recommended refresh") {
            self.recommended = Self.stableOrderMerge(old: self.recommended, new: try await c.getRecommended())
            self.log("Recommended refreshed: \(self.recommended.count)")
        }
    }

    // Recommended items are played by video ID, so the list never goes stale-by-index.
    func playRecommended(_ item: QueueItem) async {
        guard let id = item.videoId else { return }
        await self.run("Play recommended") {
            try await self.clientOrThrow().openVideoId(id)
        }
        await self.refreshFast()
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
