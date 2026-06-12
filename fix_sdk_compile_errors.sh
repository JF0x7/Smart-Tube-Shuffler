#!/usr/bin/env bash
set -euo pipefail

FILE="SmartTubecontroller/SmartTubeSDK.swift"
if [ ! -f "$FILE" ]; then
  FILE="SmartTubecontroller/SmartTubecontroller/SmartTubeSDK.swift"
fi

if [ ! -f "$FILE" ]; then
  echo "SmartTubeSDK.swift not found"
  exit 1
fi

cp "$FILE" "$FILE.bak.$(date +%s)"

python3 - "$FILE" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

# 1. Add missing commandWithRetry inside SmartTubeClient, right before command().
if "private func commandWithRetry(_ path: String" not in s:
    needle = "    private func command(_ path: String) async throws -> OKResponse"
    idx = s.find(needle)
    if idx == -1:
        print("Could not find private command() function; falling back to plain command()")
        s = s.replace("commandWithRetry(", "command(")
    else:
        block = '''    @discardableResult
    private func commandWithRetry(_ path: String, retries: Int = 2) async throws -> OKResponse {
        var lastError: Error?

        for attempt in 0...retries {
            do {
                return try await command(path)
            } catch {
                lastError = error
                let msg = String(describing: error)
                let shouldRetry = msg.contains("503") || msg.localizedCaseInsensitiveContains("Internal error")
                if attempt < retries && shouldRetry {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                    continue
                }
                throw error
            }
        }

        throw lastError ?? SmartTubeError.emptyResponse
    }

'''
        s = s[:idx] + block + s[idx:]

# 2. If any synchronous WebSocket helper accidentally got try await send(...), fix it.
# send(...) is synchronous in SmartTubeWebSocketClient.
s = s.replace("try await send(action:", "try send(action:")
s = s.replace("await send(action:", "send(action:")

# 3. Fix broken async use in non-async synchronous convenience methods if patch created any.
s = re.sub(
    r'public func (play|pause|toggle|next|previous|stop|reload|getState|toggleMute|toggleSubtitles|powerToggle)\(\) throws \{\s*try await send\(action:\s*"([^"]+)"\)\s*\}',
    r'public func \1() throws { try send(action: "\2") }',
    s
)

s = re.sub(
    r'public func ([A-Za-z0-9_]+)\(([^)]*)\) throws \{\s*try await send\(action:\s*"([^"]+)",\s*params:\s*([^}]+)\)\s*\}',
    r'public func \1(\2) throws { try send(action: "\3", params: \4) }',
    s
)

while "self.self." in s:
    s = s.replace("self.self.", "self.")

p.write_text(s)
print("Patched", p)
PY
