#!/usr/bin/env bash
set -euo pipefail
gx_project="$(cd "$(dirname "$0")/.." && pwd)"
gx_firmware="$(cd "$gx_project/../.." && pwd)/ap"
if [ ! -f "$gx_firmware/video_protocol.c" ]; then
  gx_firmware="$gx_project/tests/firmware_reference"
  echo '使用源码包内的板端协议快照作对照。'
else
  echo '使用仓库内的现有板端协议源码作对照。'
fi
gx_test_dir="$(mktemp -d /tmp/gx-ios-core.XXXXXX)"
trap 'rm -rf "$gx_test_dir"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$gx_project/GXCameraViewer/Core" -I "$gx_firmware" \
  "$gx_project/tests/test_wire.c" "$gx_project/GXCameraViewer/Core/GXVPWire.c" \
  "$gx_firmware/video_protocol.c" -o "$gx_test_dir/test_wire"
"$gx_test_dir/test_wire"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$gx_project/GXCameraViewer/Core" \
  "$gx_project/tests/test_video_geometry.c" "$gx_project/GXCameraViewer/Core/GXVideoGeometry.c" \
  -lm -o "$gx_test_dir/test_video_geometry"
"$gx_test_dir/test_video_geometry"
