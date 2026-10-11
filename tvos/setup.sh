#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  echo 'Install XcodeGen first: brew install xcodegen'
  exit 1
fi
xcodegen generate
# Uses an ignored local plist; enter only the DNS hostname, never credentials.
python3 ../ios/configure_http.py
bundle install
bundle exec pod install
open RigatoniStreamTV.xcworkspace
