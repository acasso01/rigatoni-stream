#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  echo 'Install XcodeGen first: brew install xcodegen'
  exit 1
fi
xcodegen generate
if [ -f configure_http.py ]; then
  python3 configure_http.py
elif [ -f ../ios/configure_http.py ]; then
  python3 ../ios/configure_http.py
else
  echo "Missing HTTP helper (tvos/configure_http.py). Update the complete repository."
  exit 1
fi
bundle install
bundle exec pod install
open RigatoniStreamTV.xcworkspace
