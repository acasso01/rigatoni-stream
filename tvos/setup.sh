#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  echo 'Install XcodeGen first: brew install xcodegen'
  exit 1
fi
xcodegen generate
# Optional direct-HTTP provider: one-host ATS exception (same flow as the
# iPhone build). Needed for streams AND channel-logo artwork from a direct
# HTTP provider. Blank keeps gateway-only, which remains the default.
python3 configure_http.py
bundle install
bundle exec pod install
open RigatoniStreamTV.xcworkspace
