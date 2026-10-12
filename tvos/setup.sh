#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  echo 'Install XcodeGen first: brew install xcodegen'
  exit 1
fi
xcodegen generate
test -f ../ios/configure_http.py || { echo "Missing shared HTTP helper. Update the complete repository, including ios/."; exit 1; }
python3 ../ios/configure_http.py
bundle install
bundle exec pod install
open RigatoniStreamTV.xcworkspace
