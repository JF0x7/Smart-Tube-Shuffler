import Foundation

// MARK: - Public Models

public struct SmartTubeADBBridgeResponse: Sendable {
    public let id: String?
    public let ok: Bool
    public let exitCode: Int?
    public let stdout: String
    public let stderr: String

    public init(id: String? = nil, ok: Bool, exitCode: Int?, stdout: String, stderr: String) {
        self.id = id
        self.ok = ok
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct SmartTubeADBDevice: Sendable, Equatable {
    public let serial: String
    public let state: String
}

public struct SmartTubeAutoConnectInfo: Sendable, Equatable {
    public let serial: String
    public let model: String
    public let host: String
    public let port: Int
}

public enum SmartTubeSoundMode: String, Sendable, CaseIterable {
    case auto
    case cinema
    case music
    case standard

    var vendorHex: String {
        switch self {
        case .auto: return "55"
        case .cinema: return "34"
        case .music: return "06"
        case .standard: return "00"
        }
    }
}

public enum SmartTubeAudioOutput: String, Sendable, Equatable {
    case tv
    case theater
    case unknown
}

public struct SmartTubeCECState: Sendable, Equatable {
    public var audioOutput: SmartTubeAudioOutput = .unknown
    public var subwooferLevel: Int?
    public var rearLevel: Int?
    public var immersiveAEEnabled: Bool?
    public var soundMode: SmartTubeSoundMode?

    public init(
        audioOutput: SmartTubeAudioOutput = .unknown,
        subwooferLevel: Int? = nil,
        rearLevel: Int? = nil,
        immersiveAEEnabled: Bool? = nil,
        soundMode: SmartTubeSoundMode? = nil
    ) {
        self.audioOutput = audioOutput
        self.subwooferLevel = subwooferLevel
        self.rearLevel = rearLevel
        self.immersiveAEEnabled = immersiveAEEnabled
        self.soundMode = soundMode
    }
}

public enum SmartTubeADBBridgeError: Error, LocalizedError {
    case notConnected
    case adbNotFound
    case connectFailed(String)
    case commandFailed(SmartTubeADBBridgeResponse)
    case invalidAutoConnectPayload(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "ADB device is not connected. Call connect() first."
        case .adbNotFound:
            return "Could not find the adb binary. Install Android platform-tools (e.g. `brew install android-platform-tools`)."
        case .connectFailed(let message):
            return message
        case .commandFailed(let response):
            return response.stderr.isEmpty ? "ADB command failed." : response.stderr
        case .invalidAutoConnectPayload(let payload):
            return "Could not read device info: \(payload)"
        }
    }
}

private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
    Swift.max(minValue, Swift.min(maxValue, value))
}

// MARK: - macOS Implementation (direct adb via Process)

#if os(macOS)
public final class SmartTubeADBProcessClient: @unchecked Sendable {
    public typealias UnmatchedMessageHandler = @Sendable (String) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    public let adbHost: String
    public let adbPort: Int
    public let preferredSerial: String?
    public var defaultTimeoutSeconds: TimeInterval
    public var onUnmatchedMessage: UnmatchedMessageHandler?
    public var onError: ErrorHandler?

    private let stateLock = NSLock()
    private var didConnect = false
    private var cachedADBPath: String?
    private var resolvedSerial: String?

    private static let theaterDestination = "5"
    private static let historyLines = 280

    public init(
        adbHost: String,
        adbPort: Int = 5555,
        preferredSerial: String? = nil,
        defaultTimeoutSeconds: TimeInterval = 12,
        onUnmatchedMessage: UnmatchedMessageHandler? = nil,
        onError: ErrorHandler? = nil
    ) {
        self.adbHost = adbHost
        self.adbPort = adbPort
        self.preferredSerial = preferredSerial
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.onUnmatchedMessage = onUnmatchedMessage
        self.onError = onError
    }

    public convenience init(
        host: String,
        port: Int = 5555,
        preferredSerial: String? = nil,
        defaultTimeoutSeconds: TimeInterval = 12,
        onUnmatchedMessage: UnmatchedMessageHandler? = nil,
        onError: ErrorHandler? = nil
    ) {
        self.init(
            adbHost: host,
            adbPort: port,
            preferredSerial: preferredSerial,
            defaultTimeoutSeconds: defaultTimeoutSeconds,
            onUnmatchedMessage: onUnmatchedMessage,
            onError: onError
        )
    }

    public var target: String { "\(adbHost):\(adbPort)" }

    public func connect() {
        stateLock.withLock { didConnect = false }
    }

    public func disconnect() {
        stateLock.withLock { didConnect = false }
    }

    deinit {}

    @discardableResult
    public func ping() async throws -> SmartTubeADBBridgeResponse {
        try await ensureConnected()
        return try await shell(["echo", "pong"], requireOK: true)
    }

    public func devices() async throws -> [SmartTubeADBDevice] {
        let response = try await runADB(["devices"], timeout: 5)
        return Self.parseADBDevices(response.stdout)
    }

    public func smartTubeAutoconnect() async throws -> SmartTubeAutoConnectInfo {
        try await ensureConnected()
        let serial = currentSerial
        let model = try? await runADB(["-s", serial, "shell", "getprop", "ro.product.model"], timeout: 5)
        return SmartTubeAutoConnectInfo(
            serial: serial,
            model: model?.stdout ?? "",
            host: adbHost,
            port: 8497
        )
    }

    @discardableResult
    public func setHomeTheaterSpeakers() async throws -> [SmartTubeADBBridgeResponse] {
        try await shellSequence([
            ["cmd", "hdmi_control", "cec_setting", "set", "volume_control_enabled", "1"],
            ["cmd", "hdmi_control", "setsystemaudiomode", "on"],
            ["cmd", "hdmi_control", "setarc", "on"]
        ])
    }

    @discardableResult
    public func setTVSpeakers() async throws -> [SmartTubeADBBridgeResponse] {
        try await shellSequence([
            ["cmd", "hdmi_control", "setsystemaudiomode", "off"],
            ["cmd", "hdmi_control", "setarc", "off"]
        ])
    }

    @discardableResult
    private func shellSequence(_ commands: [[String]]) async throws -> [SmartTubeADBBridgeResponse] {
        var responses: [SmartTubeADBBridgeResponse] = []
        for command in commands {
            responses.append(try await shell(command))
        }
        return responses
    }

    @discardableResult
    public func setSubwooferLevel(_ level: Int) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:44:00:FF:\(Self.hexByte(level)):FF:FF")
    }

    @discardableResult
    public func setRearLevel(_ level: Int) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:44:00:FF:FF:FF:FF:\(Self.hexByte(level))")
    }

    @discardableResult
    public func setImmersiveAE(_ enabled: Bool) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:44:00:FF:FF:FF:\(enabled ? "01" : "00")")
    }

    @discardableResult
    public func setSoundMode(_ mode: SmartTubeSoundMode) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:0D:00:\(mode.vendorHex):FF:FF:FF:FF")
    }

    @discardableResult
    public func powerToggle() async throws -> SmartTubeADBBridgeResponse {
        try await shell(["input", "keyevent", "KEYCODE_POWER"])
    }

    @discardableResult
    public func toggleMute() async throws -> SmartTubeADBBridgeResponse {
        try await shell(["input", "keyevent", "KEYCODE_VOLUME_MUTE"])
    }

    @discardableResult
    public func readTheaterLevels() async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:43:00:FF:FF:FF:FF:FF")
    }

    public func dumpCECStateRaw() async throws -> String {
        try await shell(["dumpsys hdmi_control | tail -n \(Self.historyLines)"], timeout: 15).stdout
    }

    public func getParsedCECState() async throws -> SmartTubeCECState {
        _ = try? await readTheaterLevels()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let dump = try await dumpCECStateRaw()
        return Self.parseCECState(from: dump)
    }

    private func vendorCommand(_ argsHex: String) async throws -> SmartTubeADBBridgeResponse {
        try await shell([
            "cmd", "hdmi_control", "vendorcommand",
            "--device_type", "0", "--destination", Self.theaterDestination,
            "--args", argsHex, "--id", "true"
        ])
    }

    @discardableResult
    private func shell(_ command: [String], timeout: TimeInterval? = nil, requireOK: Bool = false) async throws -> SmartTubeADBBridgeResponse {
        try await ensureConnected()
        let response = try await runADB(["-s", currentSerial, "shell"] + command, timeout: timeout ?? defaultTimeoutSeconds)
        if requireOK, !response.ok {
            stateLock.withLock { didConnect = false }
            throw SmartTubeADBBridgeError.commandFailed(response)
        }
        return response
    }

    private var currentSerial: String {
        stateLock.withLock { resolvedSerial ?? target }
    }

    private func ensureConnected() async throws {
        if stateLock.withLock({ didConnect }) { return }

        if let serial = try? await pickConnectedSerial() {
            stateLock.withLock { resolvedSerial = serial; didConnect = true }
            return
        }

        let response = try await runADB(["connect", target], timeout: 6)
        let text = (response.stdout + " " + response.stderr).lowercased()
        if text.contains("unauthorized") || text.contains("failed to authenticate") {
            throw SmartTubeADBBridgeError.connectFailed("ADB unauthorized — accept the debugging prompt on the TV.")
        }
        if text.contains("cannot connect") || text.contains("connection refused") || text.contains("unable to connect") || text.contains("failed to connect") {
            throw SmartTubeADBBridgeError.connectFailed("Cannot reach \(target) — pair the TV via Wireless Debugging or enable ADB-over-network.")
        }
        stateLock.withLock { resolvedSerial = target; didConnect = true }
    }

    private func pickConnectedSerial() async throws -> String? {
        let list = try await devices().filter { $0.state == "device" }
        if let preferredSerial, list.contains(where: { $0.serial == preferredSerial }) {
            return preferredSerial
        }
        if list.contains(where: { $0.serial == target }) { return target }
        if let network = list.first(where: { $0.serial.contains("_adb-tls-connect") || $0.serial.contains(":") }) {
            return network.serial
        }
        return list.first(where: { !$0.serial.hasPrefix("emulator-") })?.serial
    }

    @discardableResult
    private func runADB(_ args: [String], timeout: TimeInterval) async throws -> SmartTubeADBBridgeResponse {
        let adb = try adbPath()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SmartTubeADBBridgeResponse, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: adb)
                process.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutItem.cancel()

                let stdout = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: SmartTubeADBBridgeResponse(
                    ok: process.terminationStatus == 0,
                    exitCode: Int(process.terminationStatus),
                    stdout: stdout,
                    stderr: stderr
                ))
        }
    }
}

    private func adbPath() throws -> String {
        if let cached = stateLock.withLock({ cachedADBPath }) { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? "")/platform-tools/adb",
            "\(ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] ?? "")/platform-tools/adb"
        ]
        if let found = candidates.first(where: { !$0.hasPrefix("/platform-tools") && FileManager.default.isExecutableFile(atPath: $0) }) {
            stateLock.withLock { cachedADBPath = found }
            return found
        }
        throw SmartTubeADBBridgeError.adbNotFound
    }

    private static func hexByte(_ value: Int) -> String {
        String(format: "%02X", clamp(value, min: 0, max: 12))
    }
}
#endif

// MARK: - iOS Implementation (SwiftADB)

#if !os(macOS)
import SwiftADB

public final class SmartTubeADBSwiftADBClient {
    public let adbHost: String
    public let adbPort: Int
    public let preferredSerial: String?
    public var defaultTimeoutSeconds: TimeInterval

    private var connection: AdbConnection?
    private var keyPair: KeyPair?

    private static let theaterDestination = "5"
    private static let historyLines = 280

    public init(
        adbHost: String,
        adbPort: Int = 5555,
        preferredSerial: String? = nil,
        defaultTimeoutSeconds: TimeInterval = 12
    ) {
        self.adbHost = adbHost
        self.adbPort = adbPort
        self.preferredSerial = preferredSerial
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
    }

    public convenience init(
        host: String,
        port: Int = 5555,
        preferredSerial: String? = nil,
        defaultTimeoutSeconds: TimeInterval = 12
    ) {
        self.init(
            adbHost: host,
            adbPort: port,
            preferredSerial: preferredSerial,
            defaultTimeoutSeconds: defaultTimeoutSeconds
        )
    }

    public var target: String { "\(adbHost):\(adbPort)" }

    public func connect() {
        disconnect()
    }

    public func disconnect() {
        Task { await connection?.close() }
        connection = nil
        keyPair = nil
    }

    deinit {
        let c = connection
        Task { await c?.close() }
    }

    @discardableResult
    public func ping() async throws -> SmartTubeADBBridgeResponse {
        try await ensureConnected()
        return try await shell(["echo", "pong"])
    }

    public func devices() async throws -> [SmartTubeADBDevice] {
        [SmartTubeADBDevice(serial: target, state: "device")]
    }

    public func smartTubeAutoconnect() async throws -> SmartTubeAutoConnectInfo {
        try await ensureConnected()
        let response = try await shell(["getprop", "ro.product.model"])
        return SmartTubeAutoConnectInfo(
            serial: target,
            model: response.stdout,
            host: adbHost,
            port: 8497
        )
    }

    @discardableResult
    public func setHomeTheaterSpeakers() async throws -> [SmartTubeADBBridgeResponse] {
        try await shellSequence([
            ["cmd", "hdmi_control", "cec_setting", "set", "volume_control_enabled", "1"],
            ["cmd", "hdmi_control", "setsystemaudiomode", "on"],
            ["cmd", "hdmi_control", "setarc", "on"]
        ])
    }

    @discardableResult
    public func setTVSpeakers() async throws -> [SmartTubeADBBridgeResponse] {
        try await shellSequence([
            ["cmd", "hdmi_control", "setsystemaudiomode", "off"],
            ["cmd", "hdmi_control", "setarc", "off"]
        ])
    }

    @discardableResult
    private func shellSequence(_ commands: [[String]]) async throws -> [SmartTubeADBBridgeResponse] {
        var responses: [SmartTubeADBBridgeResponse] = []
        for command in commands {
            responses.append(try await shell(command))
        }
        return responses
    }

    @discardableResult
    public func setSubwooferLevel(_ level: Int) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:44:00:FF:\(Self.hexByte(level)):FF:FF")
    }

    @discardableResult
    public func setRearLevel(_ level: Int) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:44:00:FF:FF:FF:FF:\(Self.hexByte(level))")
    }

    @discardableResult
    public func setImmersiveAE(_ enabled: Bool) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:44:00:FF:FF:FF:\(enabled ? "01" : "00")")
    }

    @discardableResult
    public func setSoundMode(_ mode: SmartTubeSoundMode) async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:0D:00:\(mode.vendorHex):FF:FF:FF:FF")
    }

    @discardableResult
    public func powerToggle() async throws -> SmartTubeADBBridgeResponse {
        try await shell(["input", "keyevent", "KEYCODE_POWER"])
    }

    @discardableResult
    public func toggleMute() async throws -> SmartTubeADBBridgeResponse {
        try await shell(["input", "keyevent", "KEYCODE_VOLUME_MUTE"])
    }

    @discardableResult
    public func readTheaterLevels() async throws -> SmartTubeADBBridgeResponse {
        try await vendorCommand("F2:43:00:FF:FF:FF:FF:FF")
    }

    public func dumpCECStateRaw() async throws -> String {
        try await shell(["dumpsys hdmi_control | tail -n \(Self.historyLines)"], timeout: 15).stdout
    }

    public func getParsedCECState() async throws -> SmartTubeCECState {
        _ = try? await readTheaterLevels()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let dump = try await dumpCECStateRaw()
        return SmartTubeADBBridgeParsing.parseCECState(from: dump)
    }

    private func vendorCommand(_ argsHex: String) async throws -> SmartTubeADBBridgeResponse {
        try await shell([
            "cmd", "hdmi_control", "vendorcommand",
            "--device_type", "0", "--destination", Self.theaterDestination,
            "--args", argsHex, "--id", "true"
        ])
    }

    @discardableResult
    private func shell(_ command: [String], timeout: TimeInterval? = nil) async throws -> SmartTubeADBBridgeResponse {
        try await ensureConnected()
        guard let connection else { throw SmartTubeADBBridgeError.notConnected }
        let stream = try await connection.open(service: .shell, args: command)
        var output = ""
        while !(await stream.getIsClosed()) {
            do {
                let data = try await stream.read()
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    output += text
                }
            } catch {
                break
            }
        }
        return SmartTubeADBBridgeResponse(
            ok: true,
            exitCode: 0,
            stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: ""
        )
    }

    private func ensureConnected() async throws {
        if let connection, await connection.isConnectionEstablished() { return }

        let kp: KeyPair
        if let existing = keyPair {
            kp = existing
        } else {
            kp = try KeyPair.generate()
            keyPair = kp
        }

        let conn = AdbConnection(
            host: adbHost,
            port: UInt16(adbPort),
            keyPair: kp,
            api: 1,
            deviceName: "SmartTubeController"
        )

        let connected = try await conn.connect(
            timeout: defaultTimeoutSeconds,
            throwOnUnauthorised: false,
            useTls: false
        )

        guard connected else {
            throw SmartTubeADBBridgeError.connectFailed("ADB unauthorized or connection refused — check the TV debugging prompt.")
        }

        connection = conn
    }

    private static func hexByte(_ value: Int) -> String {
        String(format: "%02X", clamp(value, min: 0, max: 12))
    }
}
#endif

// MARK: - Typealias

#if os(macOS)
public typealias SmartTubeADBBridgeClient = SmartTubeADBProcessClient
#else
public typealias SmartTubeADBBridgeClient = SmartTubeADBSwiftADBClient
#endif

// MARK: - Parsing Helpers (platform-independent)

public enum SmartTubeADBBridgeParsing {
    public static func parseADBDevices(_ output: String) -> [SmartTubeADBDevice] {
        output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> SmartTubeADBDevice? in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard parts.count >= 2 else { return nil }
                return SmartTubeADBDevice(serial: parts[0], state: parts[1])
            }
    }

    public static func parseCECState(from dumpsys: String) -> SmartTubeCECState {
        var state = SmartTubeCECState()
        let upper = dumpsys.uppercased()

        if let audioByte = lastCapture(
            pattern: #"(?:SET SYSTEM AUDIO MODE|SYSTEM AUDIO MODE REQUEST).*(?:5F:72:|05:70:[0-9A-F]{2}:[0-9A-F]{2}:)(00|01)"#,
            in: upper,
            group: 1
        ) {
            state.audioOutput = audioByte == "01" ? .theater : .tv
        }

        if let subHex = lastCapture(pattern: #"F2:44:00:FF:([0-9A-F]{2}):FF:FF"#, in: upper, group: 1) {
            state.subwooferLevel = cecLevel(subHex)
        }

        if let rearHex = lastCapture(pattern: #"F2:44:00:FF:FF:FF:FF:([0-9A-F]{2})"#, in: upper, group: 1) {
            state.rearLevel = cecLevel(rearHex)
        }

        if let immersiveByte = lastCapture(pattern: #"F2:44:00:FF:FF:FF:(00|01)"#, in: upper, group: 1) {
            state.immersiveAEEnabled = immersiveByte == "01"
        }

        if let modeHex = lastCapture(
            pattern: #"F2:0[CD]:00:([0-9A-F]{2}):FF:(?:00|FF):FF:(?:00|FF)"#,
            in: upper,
            group: 1
        ) {
            state.soundMode = soundMode(fromHex: modeHex)
        }

        if let combined = lastCaptures(
            pattern: #"F2:43:00:FF:([0-9A-F]{2}):([0-9A-F]{2}):([0-9A-F]{2}):([0-9A-F]{2})"#,
            in: upper,
            groups: [1, 3, 4]
        ) {
            state.subwooferLevel = state.subwooferLevel ?? cecLevel(combined[0])
            state.immersiveAEEnabled = state.immersiveAEEnabled ?? (combined[1] == "01")
            state.rearLevel = state.rearLevel ?? cecLevel(combined[2])
        }

        return state
    }

    private static func cecLevel(_ hex: String) -> Int? {
        guard let value = Int(hex, radix: 16), (0...12).contains(value) else {
            return nil
        }
        return value
    }

    private static func soundMode(fromHex hex: String) -> SmartTubeSoundMode? {
        switch hex.uppercased() {
        case "55": return .auto
        case "34": return .cinema
        case "06": return .music
        case "00": return .standard
        default: return nil
        }
    }

    private static func lastCapture(pattern: String, in text: String, group: Int) -> String? {
        lastCaptures(pattern: pattern, in: text, groups: [group])?.first
    }

    private static func lastCaptures(pattern: String, in text: String, groups: [Int]) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, options: [], range: nsRange).last else { return nil }

        return groups.compactMap { group in
            guard group < match.numberOfRanges else { return nil }
            let range = match.range(at: group)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}

// MARK: - Bridge extensions (parsing helpers on the client)

public extension SmartTubeADBBridgeClient {
    static func parseADBDevices(_ output: String) -> [SmartTubeADBDevice] {
        SmartTubeADBBridgeParsing.parseADBDevices(output)
    }

    static func parseCECState(from dumpsys: String) -> SmartTubeCECState {
        SmartTubeADBBridgeParsing.parseCECState(from: dumpsys)
    }
}
