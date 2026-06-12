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

# Fix: @Published/internal properties cannot expose private helper types.
# Safer than making properties fileprivate: make local helper types fileprivate.
s = re.sub(r'\bprivate\s+struct\s+(RawFormat|RawQueueItem|RawSuggestion|RawTrack|TrackItem|TrackOption|QueueDisplayItem|FormatDisplayItem)\b',
           r'fileprivate struct \1', s)
s = re.sub(r'\bprivate\s+enum\s+(PlayerPanel|InspectorPanel|SoundMode|ConnectionState|Route)\b',
           r'fileprivate enum \1', s)

# If exact type names differ, convert all private helper structs/enums before ContentView to fileprivate.
before_marker = "struct ContentView"
if before_marker in s:
    head, tail = s.split(before_marker, 1)
    head = re.sub(r'\bprivate\s+(struct|enum)\s+', r'fileprivate \1 ', head)
    s = head + before_marker + tail

# Fix Swift 6 explicit self capture inside Task closures.
# These are intentionally scoped to common property/method names from this UI.
names = [
    "vm", "theater", "videoText", "searchText", "queueText",
    "selectedVideoFormat", "selectedAudioFormat", "selectedSubtitleFormat",
    "subwooferLevel", "rearLevel", "soundMode", "seekValue",
    "isDraggingSeek", "inspectorSelection", "selectedQueueItem"
]

for name in names:
    s = re.sub(rf'(?<![\w.$]){name}\b', f'self.{name}', s)

# Undo bad replacements in declarations, bindings, and property wrappers.
s = s.replace("@StateObject private var self.vm", "@StateObject private var vm")
s = s.replace("@State private var self.", "@State private var ")
s = s.replace("@Binding var self.", "@Binding var ")
s = s.replace("@Published var self.", "@Published var ")
s = s.replace("@Published private(set) var self.", "@Published private(set) var ")
s = s.replace("private var self.", "private var ")
s = s.replace("fileprivate var self.", "fileprivate var ")
s = s.replace("let self.", "let ")
s = s.replace("var self.", "var ")
s = s.replace("$self.", "$")

# Undo replacements in function signatures and key paths.
s = re.sub(r'func\s+self\.', 'func ', s)
s = re.sub(r'case\s+self\.', 'case .', s)
s = re.sub(r'\bself\.self\.', 'self.', s)

# Fix common closure patterns manually.
s = s.replace("Task { await vm.", "Task { await self.vm.")
s = s.replace("Task { try await vm.", "Task { try await self.vm.")
s = s.replace("Task { try? await vm.", "Task { try? await self.vm.")
s = s.replace("Task { await self.self.vm.", "Task { await self.vm.")
s = s.replace("Task { try await self.self.vm.", "Task { try await self.vm.")
s = s.replace("Task { try? await self.self.vm.", "Task { try? await self.vm.")

# Fix accidental double self everywhere.
while "self.self." in s:
    s = s.replace("self.self.", "self.")

# Fix SwiftUI Slider trailing closure issue if present.
s = re.sub(
    r'Slider\(value:\s*([^,\n]+),\s*in:\s*([^,\n]+),\s*step:\s*([^)\n]+)\)\s*\{\s*editing\s+in',
    r'Slider(value: \1, in: \2, step: \3, onEditingChanged: { editing in',
    s
)
s = re.sub(
    r'Slider\(value:\s*([^,\n]+),\s*in:\s*([^)\n]+)\)\s*\{\s*editing\s+in',
    r'Slider(value: \1, in: \2, onEditingChanged: { editing in',
    s
)

p.write_text(s)
print("Patched", p)
PY
