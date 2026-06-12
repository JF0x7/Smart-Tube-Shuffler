#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT"

echo "Project root: $(pwd)"

python3 - <<'PY'
from pathlib import Path
import re
import time

root = Path.cwd()

def first_existing(candidates):
    for c in candidates:
        p = root / c
        if p.exists():
            return p
    return None

sdk = first_existing([
    "SmartTubecontroller/SmartTubeSDK.swift",
    "SmartTubecontroller/SmartTubecontroller/SmartTubeSDK.swift",
    "SmartTubeSDK.swift",
])

bridge = first_existing([
    "SmartTubecontroller/SmartTubeADBBridge.swift",
    "SmartTubecontroller/SmartTubecontroller/SmartTubeADBBridge.swift",
    "SmartTubeADBBridge.swift",
])

if not sdk:
    raise SystemExit("SmartTubeSDK.swift not found")

stamp = str(int(time.time()))

# -------------------------
# Patch SmartTubeSDK.swift
# -------------------------
s = sdk.read_text()
(sdk.with_suffix(sdk.suffix + f".bak.{stamp}")).write_text(s)

video_format = r'''public struct VideoFormat: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if !formatId.isEmpty { return formatId }
        return "video-\(label ?? "")-\(width ?? -999)-\(height ?? -999)-\(codec ?? "")-\(bitrate ?? -1)"
    }

    public let formatId: String
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let codec: String?
    public let bitrate: Int?
    public let label: String?
    public let language: String?
    public let isSelected: Bool?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case width
        case height
        case frameRate = "frame_rate"
        case codec
        case bitrate
        case label
        case language
        case isSelected = "is_selected"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatId = (try? c.decode(String.self, forKey: .formatId)) ?? ""
        self.width = Self.decodeInt(c, .width)
        self.height = Self.decodeInt(c, .height)
        self.frameRate = Self.decodeDouble(c, .frameRate)
        self.codec = try? c.decode(String.self, forKey: .codec)
        self.bitrate = Self.decodeInt(c, .bitrate)
        self.label = try? c.decode(String.self, forKey: .label)
        self.language = try? c.decode(String.self, forKey: .language)
        self.isSelected = try? c.decode(Bool.self, forKey: .isSelected)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let v = try? c.decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Int(v) }
        return nil
    }

    private static func decodeDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let v = try? c.decode(Double.self, forKey: key) { return v }
        if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Double(v) }
        return nil
    }
}'''

audio_format = r'''public struct AudioFormat: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if !formatId.isEmpty { return formatId }
        return "audio-\(label ?? "")-\(codec ?? "")-\(bitrate ?? -1)-\(language ?? "")"
    }

    public let formatId: String
    public let codec: String?
    public let language: String?
    public let languageLabel: String?
    public let bitrate: Int?
    public let label: String?
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let isSelected: Bool?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case codec
        case language
        case languageLabel = "language_label"
        case bitrate
        case label
        case width
        case height
        case frameRate = "frame_rate"
        case isSelected = "is_selected"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatId = (try? c.decode(String.self, forKey: .formatId)) ?? ""
        self.codec = try? c.decode(String.self, forKey: .codec)
        self.language = try? c.decode(String.self, forKey: .language)
        self.languageLabel = try? c.decode(String.self, forKey: .languageLabel)
        self.bitrate = Self.decodeInt(c, .bitrate)
        self.label = try? c.decode(String.self, forKey: .label)
        self.width = Self.decodeInt(c, .width)
        self.height = Self.decodeInt(c, .height)
        self.frameRate = Self.decodeDouble(c, .frameRate)
        self.isSelected = try? c.decode(Bool.self, forKey: .isSelected)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let v = try? c.decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Int(v) }
        return nil
    }

    private static func decodeDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let v = try? c.decode(Double.self, forKey: key) { return v }
        if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Double(v) }
        return nil
    }
}'''

subtitle_format = r'''public struct SubtitleFormat: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if !formatId.isEmpty { return "\(formatId)-\(label ?? language ?? languageLabel ?? "")" }
        return "subtitle-\(label ?? "")-\(language ?? "")"
    }

    public let formatId: String
    public let language: String?
    public let languageLabel: String?
    public let label: String?
    public let codec: String?
    public let bitrate: Int?
    public let isSelected: Bool?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case language
        case languageLabel = "language_label"
        case label
        case codec
        case bitrate
        case isSelected = "is_selected"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatId = (try? c.decode(String.self, forKey: .formatId)) ?? ""
        self.language = try? c.decode(String.self, forKey: .language)
        self.languageLabel = try? c.decode(String.self, forKey: .languageLabel)
        self.label = try? c.decode(String.self, forKey: .label)
        self.codec = try? c.decode(String.self, forKey: .codec)
        self.bitrate = Self.decodeInt(c, .bitrate)
        self.isSelected = try? c.decode(Bool.self, forKey: .isSelected)
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let v = try? c.decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? c.decode(String.self, forKey: key) { return Int(v) }
        return nil
    }
}'''

s, n1 = re.subn(r'public struct VideoFormat: Codable, Sendable, Equatable, Identifiable \{.*?\n\}', video_format, s, count=1, flags=re.S)
s, n2 = re.subn(r'public struct AudioFormat: Codable, Sendable, Equatable, Identifiable \{.*?\n\}', audio_format, s, count=1, flags=re.S)
s, n3 = re.subn(r'public struct SubtitleFormat: Codable, Sendable, Equatable, Identifiable \{.*?\n\}', subtitle_format, s, count=1, flags=re.S)

if (n1, n2, n3) != (1, 1, 1):
    raise SystemExit(f"Could not patch all format structs: video={n1} audio={n2} subtitle={n3}")

s = re.sub(
    r'public func getVideoFormats\(\) async throws -> \[VideoFormat\] \{\s*try await request\("GET", "/api/player/formats/video", response: \[VideoFormat\]\.self\)\s*\}',
    '''public func getVideoFormats() async throws -> [VideoFormat] {
        let items = try await request("GET", "/api/player/formats/video", response: [VideoFormat].self)
        return items.filter { !$0.formatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }''',
    s,
    count=1,
    flags=re.S,
)

s = re.sub(
    r'public func getAudioFormats\(\) async throws -> \[AudioFormat\] \{\s*try await request\("GET", "/api/player/formats/audio", response: \[AudioFormat\]\.self\)\s*\}',
    '''public func getAudioFormats() async throws -> [AudioFormat] {
        let items = try await request("GET", "/api/player/formats/audio", response: [AudioFormat].self)
        return items.filter { !$0.formatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }''',
    s,
    count=1,
    flags=re.S,
)

s = re.sub(
    r'public func getSubtitleFormats\(\) async throws -> \[SubtitleFormat\] \{\s*try await request\("GET", "/api/player/formats/subtitle", response: \[SubtitleFormat\]\.self\)\s*\}',
    '''public func getSubtitleFormats() async throws -> [SubtitleFormat] {
        let items = try await request("GET", "/api/player/formats/subtitle", response: [SubtitleFormat].self)
        return items.filter { !$0.formatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }''',
    s,
    count=1,
    flags=re.S,
)

# Absolute TV volume endpoint can return 422 even when step volume works. Fallback to step commands.
s = re.sub(
    r'@discardableResult\s+public func setTheaterVolume\(_ volume: Int\) async throws -> OKResponse \{\s*try await request\("PUT", "/api/theater/volume", body: TheaterVolumeBody\(volume: volume\), response: OKResponse\.self\)\s*\}',
    '''@discardableResult
    public func setTheaterVolume(_ volume: Int) async throws -> OKResponse {
        let target = max(0, min(100, volume))
        do {
            return try await request("PUT", "/api/theater/volume", body: TheaterVolumeBody(volume: target), response: OKResponse.self)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            guard message.contains("422") || message.localizedCaseInsensitiveContains("Invalid JSON") else {
                throw error
            }

            let current = (try? await getTheaterVolume().volume) ?? (try? await getTheater().volume) ?? target
            let delta = target - current
            if delta == 0 { return OKResponse(ok: true) }

            for _ in 0..<min(abs(delta), 100) {
                if delta > 0 {
                    _ = try await theaterVolumeUp()
                } else {
                    _ = try await theaterVolumeDown()
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            return OKResponse(ok: true)
        }
    }''',
    s,
    count=1,
    flags=re.S,
)

# Retry next/previous because SmartTube occasionally throws transient 503 during player transitions.
s = s.replace('@discardableResult public func next() async throws -> OKResponse { try await command("/api/player/next") }',
              '@discardableResult public func next() async throws -> OKResponse { try await commandWithRetry("/api/player/next") }')
s = s.replace('@discardableResult public func previous() async throws -> OKResponse { try await command("/api/player/previous") }',
              '@discardableResult public func previous() async throws -> OKResponse { try await commandWithRetry("/api/player/previous") }')

if 'private func commandWithRetry(_ path: String' not in s:
    s = s.replace(
        '    @discardableResult\n    private func command(_ path: String) async throws -> OKResponse {\n        try await request("POST", path, response: OKResponse.self)\n    }',
        '''    @discardableResult
    private func commandWithRetry(_ path: String, retries: Int = 2) async throws -> OKResponse {
        var lastError: Error?
        for attempt in 0...retries {
            do {
                return try await command(path)
            } catch {
                lastError = error
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? SmartTubeError.emptyResponse
    }

    @discardableResult
    private func command(_ path: String) async throws -> OKResponse {
        try await request("POST", path, response: OKResponse.self)
    }'''
    )

# Be explicit for NanoHTTPD: no connection reuse poisoning, correct body length.
if 'forHTTPHeaderField: "Connection"' not in s:
    s = s.replace('request.setValue("application/json", forHTTPHeaderField: "Content-Type")',
                  'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n        request.setValue("close", forHTTPHeaderField: "Connection")')

s = s.replace('request.httpBody = try encoder.encode(body)',
              'request.httpBody = try encoder.encode(body)\n                request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")')
# avoid duplicate content-length if run twice
s = s.replace('request.httpBody = try encoder.encode(body)\n                request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")\n                request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")',
              'request.httpBody = try encoder.encode(body)\n                request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")')

sdk.write_text(s)
print(f"Patched SDK: {sdk}")

# ------------------------------
# Patch SmartTubeADBBridge.swift
# ------------------------------
if bridge:
    b = bridge.read_text()
    (bridge.with_suffix(bridge.suffix + f".bak.{stamp}")).write_text(b)

    b = b.replace('state.subwooferLevel = Int(subHex, radix: 16)', 'state.subwooferLevel = cecLevel(subHex)')
    b = b.replace('state.rearLevel = Int(rearHex, radix: 16)', 'state.rearLevel = cecLevel(rearHex)')
    b = b.replace('state.subwooferLevel = state.subwooferLevel ?? Int(combined[0], radix: 16)', 'state.subwooferLevel = state.subwooferLevel ?? cecLevel(combined[0])')
    b = b.replace('state.rearLevel = state.rearLevel ?? Int(combined[2], radix: 16)', 'state.rearLevel = state.rearLevel ?? cecLevel(combined[2])')

    if 'private static func cecLevel(_ hex: String)' not in b:
        b = b.replace('    private static func soundMode(fromHex hex: String) -> SmartTubeSoundMode? {',
'''    private static func cecLevel(_ hex: String) -> Int? {
        guard let value = Int(hex, radix: 16), (0...12).contains(value) else {
            return nil
        }
        return value
    }

    private static func soundMode(fromHex hex: String) -> SmartTubeSoundMode? {''')

    bridge.write_text(b)
    print(f"Patched ADB bridge parser: {bridge}")
else:
    print("SmartTubeADBBridge.swift not found; skipped CEC parser patch")

print("Done. Clean build in Xcode, then test: refresh formats, set absolute TV volume, previous/next.")
PY

