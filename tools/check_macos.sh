#!/usr/bin/env bash
set -euo pipefail
gx_project="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v xcodebuild >/dev/null; then
  echo '请在安装了完整 Xcode（15 或以上）的 Mac 上运行。' >&2
  exit 1
fi
xcodebuild -resolvePackageDependencies -project "$gx_project/GXCameraViewer.xcodeproj" -scheme GXCameraViewer
xcodebuild -project "$gx_project/GXCameraViewer.xcodeproj" -scheme GXCameraViewer \
  -destination 'generic/platform=iOS' -derivedDataPath "$gx_project/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
