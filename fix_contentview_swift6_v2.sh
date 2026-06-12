#!/usr/bin/env bash
set -euo pipefail

FILE="SmartTubecontroller/ContentView.swift"
if [ ! -f "$FILE" ]; then
  FILE="SmartTubecontroller/SmartTubecontroller/ContentView.swift"
fi

if [ ! -f "$FILE" ]; then
  echo "ContentView.swift not found"
  exit 1
fi

cp "$FILE" "$FILE.bak.$(date +%s)"

python3 - "$FILE" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

# Undo broken earlier regex edits.
s = re.sub(r'\b(private\s+var|private\s+func|var|func)\s+self\.', r'\1 ', s)
s = s.replace("case self.", "case .")
while "self.self." in s:
    s = s.replace("self.self.", "self.")

# Remove iOS-only modifiers if they came back.
s = re.sub(r'\n\s*\.textInputAutocapitalization\(\.never\)', '', s)
s = re.sub(r'\n\s*\.keyboardType\(\.numberPad\)', '', s)

# Swift 6 explicit self in View closures, but do not touch SwiftUI bindings like $vm.xxx.
s = re.sub(r'(?<![\w.$])vm\.', 'self.vm.', s)

# Swift 6 explicit self inside ViewModel escaping async closures.
repls = {
    "await runAction(": "await self.runAction(",
    "try requireClient()": "try self.requireClient()",
    "try await requireClient()": "try await self.requireClient()",
    "requireClient().": "self.requireClient().",
    "try requireBridge()": "try self.requireBridge()",
    "requireBridge().": "self.requireBridge().",
    "try await refreshAll()": "try await self.refreshAll()",
    "await refreshTracks()": "await self.refreshTracks()",
    "await refreshCEC()": "await self.refreshCEC()",
    "try? await refreshAll()": "try? await self.refreshAll()",
    "videoInput = \"\"": "self.videoInput = \"\"",
    "queueInput = \"\"": "self.queueInput = \"\"",
    "queue = try await c.getQueue()": "self.queue = try await c.getQueue()",
    "queue = []": "self.queue = []",
    "theaterState = try? await c.getTheater()": "self.theaterState = try? await c.getTheater()",
    "do { try socketCommand(socket) } catch { fail(error.localizedDescription) }":
        "do { try socketCommand(socket) } catch { self.fail(error.localizedDescription) }",
    "Task { await self.runAction(\"Sending command…\") { try await rest(try self.requireClient()) } }":
        "Task { await self.runAction(\"Sending command…\") { try await rest(try self.requireClient()) } }",
}

for a, b in repls.items():
    s = s.replace(a, b)

# Fix common self omissions in SwiftUI closure bodies.
s = s.replace("if !isDraggingSeek { seekValue = self.vm.progress }",
              "if !self.isDraggingSeek { self.seekValue = self.vm.progress }")
s = s.replace("theaterVolume = Double(state.volume)",
              "self.theaterVolume = Double(state.volume)")
s = s.replace("await self.vm.setTheaterVolume(theaterVolume)",
              "await self.vm.setTheaterVolume(self.theaterVolume)")
s = s.replace("await self.vm.setSubwoofer(subwooferLevel)",
              "await self.vm.setSubwoofer(self.subwooferLevel)")
s = s.replace("await self.vm.setRear(rearLevel)",
              "await self.vm.setRear(self.rearLevel)")

# macOS Slider trailing closure must be onEditingChanged, not an unlabeled trailing closure.
s = s.replace(
'''Slider(value: $theaterVolume, in: 0...100) { editing in
                        if !editing { Task { await self.vm.setTheaterVolume(self.theaterVolume) } }
                    }''',
'''Slider(value: $theaterVolume, in: 0...100, onEditingChanged: { editing in
                        if !editing { Task { await self.vm.setTheaterVolume(self.theaterVolume) } }
                    })'''
)

s = s.replace(
'''Slider(value: $subwooferLevel, in: 0...12, step: 1) { editing in
                            if !editing { Task { await self.vm.setSubwoofer(self.subwooferLevel) } }
                        }''',
'''Slider(value: $subwooferLevel, in: 0...12, step: 1, onEditingChanged: { editing in
                            if !editing { Task { await self.vm.setSubwoofer(self.subwooferLevel) } }
                        })'''
)

s = s.replace(
'''Slider(value: $rearLevel, in: 0...12, step: 1) { editing in
                            if !editing { Task { await self.vm.setRear(self.rearLevel) } }
                        }''',
'''Slider(value: $rearLevel, in: 0...12, step: 1, onEditingChanged: { editing in
                            if !editing { Task { await self.vm.setRear(self.rearLevel) } }
                        })'''
)

# Clean accidental double self again.
while "self.self." in s:
    s = s.replace("self.self.", "self.")

p.write_text(s)
print(f"Patched {p}")
PY
