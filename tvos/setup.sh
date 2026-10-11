#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  echo 'Install XcodeGen first: brew install xcodegen'
  exit 1
fi
xcodegen generate
# No configure_http.py step here: tvOS uses the same HTTPS gateway as the iPhone
# build for HTTP providers. Direct HTTP would need its own ATS exception.
bundle install
bundle exec pod install
open RigatoniStreamTV.xcworkspace
