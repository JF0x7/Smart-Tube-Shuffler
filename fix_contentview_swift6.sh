#!/usr/bin/env bash
set -euo pipefail

FILE="SmartTubecontroller/ContentView.swift"

if [ ! -f "$FILE" ]; then
  echo "Missing $FILE"
  exit 1
fi

cp "$FILE" "$FILE.bak.$(date +%s)"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("SmartTubecontroller/ContentView.swift")
s = p.read_text()

# Add explicit self. for ContentView's vm references, but don't break SwiftUI bindings like $vm.host
s = re.sub(r'(?<![\w.$])vm\.', 'self.vm.', s)

# Add explicit self. for computed view properties referenced inside ViewBuilder closures
for name in [
    "connectionCard", "nowPlayingCard", "transportCard", "sendVideoCard",
    "queueCard", "formatsCard", "theaterCard", "adbBridgeCard", "errorCard",
    "stateColor"
]:
    s = re.sub(rf'(?<![\w.]){name}\b', f'self.{name}', s)

# Avoid double self.self if script is run twice
s = s.replace("self.self.", "self.")

# Fix bad async task closures like Task { _ in ... } or .task { _ in ... }
s = re.sub(r'Task\s*\{\s*_\s+in', 'Task {', s)
s = re.sub(r'\.task\s*\{\s*_\s+in', '.task {', s)
s = re.sub(r'(\.task\s*\([^)]*\)\s*)\{\s*_\s+in', r'\1{', s)

p.write_text(s)
print("Patched", p)
PY
