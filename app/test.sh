#!/bin/bash
# Runs Gauge's tests (Swift Testing).
#
#   ./test.sh                 all tests
#   ./test.sh --filter Notices one suite
#
# With only the Command Line Tools installed, Swift Testing lives outside the default search paths,
# so point the compiler and loader at it. Xcode needs no extra flags.
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=()
DEV="$(xcode-select -p)/Library/Developer"
if [[ "$(xcode-select -p)" == *CommandLineTools* && -d "$DEV/Frameworks/Testing.framework" ]]; then
  FLAGS=(-Xswiftc "-F$DEV/Frameworks" -Xlinker "-F$DEV/Frameworks"
         -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi
swift test "${FLAGS[@]}" "$@"
