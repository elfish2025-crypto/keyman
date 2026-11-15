#!/bin/bash
set -euo pipefail

keyman_developer_dir="$(xcode-select -p)"
keyman_expected_dir="/Library/Developer/CommandLineTools"

if [[ "$keyman_developer_dir" != "$keyman_expected_dir" ]]; then
  # Full Xcode supplies Swift Testing through its selected toolchain.
  exec swift test "$@"
fi

keyman_testing_frameworks="$keyman_developer_dir/Library/Developer/Frameworks"
keyman_testing_interop="$keyman_developer_dir/Library/Developer/usr/lib"
keyman_testing_binary="$keyman_testing_frameworks/Testing.framework/Testing"
keyman_interop_binary="$keyman_testing_interop/lib_TestingInterop.dylib"

if [[ ! -f "$keyman_testing_binary" || ! -f "$keyman_interop_binary" ]]; then
  echo "error: Command Line Tools Swift Testing runtime is incomplete" >&2
  exit 2
fi

exec swift test \
  -Xswiftc -F \
  -Xswiftc "$keyman_testing_frameworks" \
  -Xlinker -F \
  -Xlinker "$keyman_testing_frameworks" \
  -Xlinker -rpath \
  -Xlinker "$keyman_testing_frameworks" \
  -Xlinker -rpath \
  -Xlinker "$keyman_testing_interop" \
  "$@"
