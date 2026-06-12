#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"

echo "Project root: $ROOT"

find_file() {
  local name="$1"
  local f
  for f in \
    "$ROOT/SmartTubecontroller/$name" \
    "$ROOT/SmartTubecontroller/SmartTubecontroller/$name" \
    "$ROOT/$name"; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

SDK="$(find_file SmartTubeSDK.swift || true)"
BRIDGE="$(find_file SmartTubeADBBridge.swift || true)"
CONTENT="$(find_file ContentView.swift || true)"

[ -n "$SDK" ] || { echo "SmartTubeSDK.swift not found"; exit 1; }
[ -n "$CONTENT" ] || { echo "ContentView.swift not found"; exit 1; }

cp "$SDK" "$SDK.bak.$(date +%s)"
cp "$CONTENT" "$CONTENT.bak.$(date +%s)"
[ -n "$BRIDGE" ] && cp "$BRIDGE" "$BRIDGE.bak.$(date +%s)"

python3 - "$SDK" "$CONTENT" "$BRIDGE" <<'PY'
from pathlib import Path
import re, sys

sdk = Path(sys.argv[1])
content = Path(sys.argv[2])
bridge = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

# -------------------------
# 1) Fix SmartTubeSDK HTTP requests
# -------------------------
s = sdk.read_text()

# Do not poison NanoHTTPD keep-alive connections. The SmartTube server may not
# consume bodies for no-body POST routes, so force close after every request.
if 'forHTTPHeaderField: "Connection"' not in s:
    s = s.replace(
        'request.setValue("application/json", forHTTPHeaderField: "Accept")',
        'request.setValue("application/json", forHTTPHeaderField: "Accept")\n        request.setValue("close", forHTTPHeaderField: "Connection")',
        1
    )

# Content-Type should only be sent when a JSON body is actually present.
s = s.replace('        request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n\n        if auth {',
              '        if auth {')

# Remove bad previous patches that forced an empty JSON body for no-body POSTs.
s = re.sub(r'\n\s*request\.httpBody\s*=\s*Data\("\{\}"\.utf8\)', '', s)
s = re.sub(r'\n\s*request\.httpBody\s*=\s*try\s+encoder\.encode\(EmptyBody\(\)\)', '', s)
s = re.sub(r'\n\s*request\.httpBody\s*=\s*try\s+encoder\.encode\(Optional<EmptyBody>\.some\(EmptyBody\(\)\)\)', '', s)

# Make command() explicitly use no body.
command_re = r'''@discardableResult\s+private func command\(_ path: String\) async throws -> OKResponse \{.*?\n    \}'''
command_new = '''@discardableResult
    private func command(_ path: String) async throws -> OKResponse {
        // Important: do not send `{}` here. SmartTube/NanoHTTPD no-body POST
        // handlers may leave that body unread on keep-alive connections, causing
        // the next request to be parsed as "{}POST".
        try await request("POST", path, response: OKResponse.self)
    }'''
s = re.sub(command_re, command_new, s, count=1, flags=re.S)

# Make the no-body overload truly no-body.
req_nobody_re = r'''private func request<T: Decodable>\(\s*_ method: String,\s*_ path: String,\s*query: \[String: String\?\] = \[:\],\s*auth: Bool = true,\s*response: T.Type\s*\) async throws -> T \{.*?\n    \}'''
req_nobody_new = '''private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        auth: Bool = true,
        response: T.Type
    ) async throws -> T {
        try await request(method, path, query: query, auth: auth, body: Optional<EmptyBody>.none, response: response)
    }'''
s = re.sub(req_nobody_re, req_nobody_new, s, count=1, flags=re.S)

# Add Content-Type inside the body branch if missing.
s = s.replace(
'''        if let body {
            do {
                request.httpBody = try encoder.encode(body)''',
'''        if let body {
            do {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(body)'''
)
# Avoid duplicate Content-Type if script runs again.
s = s.replace(
'''request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")''',
'''request.setValue("application/json", forHTTPHeaderField: "Content-Type")'''
)

sdk.write_text(s)
print('Patched HTTP request layer:', sdk)

# -------------------------
# 2) Improve WebSocket close handling + fallback polling in ContentView
# -------------------------
c = content.read_text()

# Ensure Combine import exists for ObservableObject/@Published.
if 'import Combine' not in c:
    c = c.replace('import SwiftUI', 'import SwiftUI\nimport Combine', 1)

# Add fallback polling task storage.
if 'fallbackPollTask' not in c:
    c = c.replace(
        '    private var bridge: SmartTubeADBBridgeClient?\n',
        '    private var bridge: SmartTubeADBBridgeClient?\n    private var fallbackPollTask: Task<Void, Never>?\n',
        1
    )

# Add fallback polling helpers before refreshAllTolerant.
if 'private func startFallbackPolling()' not in c:
    helper = r'''
    private func startFallbackPolling() {
        guard fallbackPollTask == nil else { return }
        guard isConnected else { return }
        log("Realtime fallback polling started")
        fallbackPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                await self.refreshPlayerOnly()
            }
        }
    }

    private func stopFallbackPolling() {
        fallbackPollTask?.cancel()
        fallbackPollTask = nil
    }

    private func refreshPlayerOnly() async {
        guard let client else { return }
        do {
            playerState = try await client.getPlayer()
        } catch {
            // Keep this quiet to avoid spamming the log every 1.5s.
        }
    }

'''
    c = c.replace('    func refreshAllTolerant() async {', helper + '    func refreshAllTolerant() async {', 1)

# Realtime should not become the main red error if REST works.
c = c.replace(
'''                self?.isRealtimeConnected = false
                self?.lastError = "Realtime error: \(error.localizedDescription)"
                self?.log(self?.lastError ?? "Realtime error")''',
'''                self?.isRealtimeConnected = false
                self?.log("Realtime warning: \(error.localizedDescription)")
                self?.startFallbackPolling()'''
)

c = c.replace(
'''                self?.isRealtimeConnected = false
                self?.log("Realtime closed")''',
'''                self?.isRealtimeConnected = false
                self?.log("Realtime closed; using polling fallback")
                self?.startFallbackPolling()'''
)

# Stop fallback once realtime is receiving again.
c = c.replace(
'''                    self.isRealtimeConnected = true
                    self.log("Realtime connected\(deviceName.map { " to \($0)" } ?? "")")''',
'''                    self.isRealtimeConnected = true
                    self.stopFallbackPolling()
                    self.log("Realtime connected\(deviceName.map { " to \($0)" } ?? "")")'''
)

c = c.replace(
'''                    self.playerState = state
                    self.isRealtimeConnected = true''',
'''                    self.playerState = state
                    self.isRealtimeConnected = true
                    self.stopFallbackPolling()'''
)

# Stop fallback on manual disconnect / token removal.
c = c.replace(
'''        realtime?.disconnect()
        realtime = nil
        isRealtimeConnected = false
        phase = .needsPairing("Token removed")''',
'''        realtime?.disconnect()
        realtime = nil
        stopFallbackPolling()
        isRealtimeConnected = false
        phase = .needsPairing("Token removed")'''
)

c = c.replace(
'''        realtime?.disconnect()
        realtime = nil
        client = nil
        isConnected = false''',
'''        realtime?.disconnect()
        realtime = nil
        stopFallbackPolling()
        client = nil
        isConnected = false'''
)

# Diagnostics: CEC output fallback from REST theater state so it doesn't show nil when parser has not run yet.
c = c.replace(
'''            "CEC: output=\(cecState?.audioOutput.rawValue ?? "nil") sub=\(cecState?.subwooferLevel?.description ?? "nil") rear=\(cecState?.rearLevel?.description ?? "nil") immersive=\(cecState?.immersiveAEEnabled?.description ?? "nil") mode=\(cecState?.soundMode?.rawValue ?? "nil")",''',
'''            "CEC: output=\(cecState?.audioOutput.rawValue ?? theaterState?.audioOutput ?? "nil") sub=\(cecState?.subwooferLevel?.description ?? "nil") rear=\(cecState?.rearLevel?.description ?? "nil") immersive=\(cecState?.immersiveAEEnabled?.description ?? "nil") mode=\(cecState?.soundMode?.rawValue ?? "nil")",'''
)

content.write_text(c)
print('Patched UI realtime fallback/logging:', content)

# -------------------------
# 3) Improve CEC parsing freshness in ADB bridge wrapper
# -------------------------
if bridge and bridge.exists():
    b = bridge.read_text()
    b = re.sub(
        r'''public func getParsedCECState\(\) async throws -> SmartTubeCECState \{\s*let dump = try await dumpCECStateRaw\(\)\s*return Self\.parseCECState\(from: dump\)\s*\}''',
        '''public func getParsedCECState() async throws -> SmartTubeCECState {
        // Ask the theater device to report its level state, then read dumpsys.
        // Some TVs only put sub/rear/immersive bytes into dumpsys after this vendor query.
        _ = try? await readTheaterLevels()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let dump = try await dumpCECStateRaw()
        return Self.parseCECState(from: dump)
    }''',
        b,
        count=1,
        flags=re.S
    )
    bridge.write_text(b)
    print('Patched ADB bridge CEC refresh:', bridge)
PY

echo "Done. Clean build once in Xcode."
echo "If Play/Next still fails, quit the macOS app, restart node bridge.js, then run again."

