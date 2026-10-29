#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Darwin ]; then
  echo 'Language Noob requires macOS 14 or later.' >&2
  exit 1
fi
cd "$root"
sdk=$(xcrun --sdk macosx --show-sdk-path)
developer=$(xcode-select -p)
export CLANG_MODULE_CACHE_PATH="$root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/module-cache"
export MACOSX_DEPLOYMENT_TARGET=14.0
exec "$developer/usr/bin/swift" "$@" --sdk "$sdk" --triple "$(uname -m)-apple-macosx14.0" --cache-path "$root/.build/cache" --config-path "$root/.build/config" --security-path "$root/.build/security"
