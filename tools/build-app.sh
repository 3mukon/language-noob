#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -s)" in Darwin) ;; *) echo 'Language Noob requires macOS 14 or later.' >&2; exit 1 ;; esac
sdk=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}
swiftc=${SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}
target=${SWIFT_TARGET:-$(uname -m)-apple-macosx14.0}
build="$root/.build/language-noob"
cache="$build/module-cache"
rm -rf "$build"
mkdir -p "$cache" "$build/Frameworks" "$build/Tests"
common="-target $target -sdk $sdk -module-cache-path $cache"

"$swiftc" $common -emit-module -emit-library -module-name StudyCore -enable-testing \
  -Xlinker -install_name -Xlinker '@rpath/libStudyCore.dylib' \
  -o "$build/libStudyCore.dylib" -emit-module-path "$build/StudyCore.swiftmodule" "$root"/Sources/StudyCore/*.swift
"$swiftc" $common -emit-module -emit-library -module-name StudyStorage -enable-testing \
  -Xlinker -install_name -Xlinker '@rpath/libStudyStorage.dylib' \
  -I "$build" -L "$build" -lStudyCore -Xlinker -rpath -Xlinker '@loader_path' \
  -o "$build/libStudyStorage.dylib" -emit-module-path "$build/StudyStorage.swiftmodule" "$root"/Sources/StudyStorage/*.swift
"$swiftc" $common -emit-module -emit-library -module-name StudyAssistant -enable-testing \
  -Xlinker -install_name -Xlinker '@rpath/libStudyAssistant.dylib' \
  -I "$build" -L "$build" -lStudyCore -Xlinker -rpath -Xlinker '@loader_path' \
  -o "$build/libStudyAssistant.dylib" -emit-module-path "$build/StudyAssistant.swiftmodule" "$root"/Sources/StudyAssistant/*.swift

"$swiftc" $common -emit-module -emit-library -module-name StudyRuntime -enable-testing \
  -Xlinker -install_name -Xlinker '@rpath/libStudyRuntime.dylib' \
  -I "$build" -L "$build" -lStudyCore -lStudyStorage -lStudyAssistant -Xlinker -rpath -Xlinker '@loader_path' \
  -o "$build/libStudyRuntime.dylib" -emit-module-path "$build/StudyRuntime.swiftmodule" "$root"/Sources/StudyRuntime/*.swift

cat > "$build/BundleModule.swift" <<'EOF'
import Foundation
extension Bundle { static var module: Bundle { Bundle.main } }
EOF
"$swiftc" $common -parse-as-library -emit-executable -I "$build" -L "$build" \
  -lStudyCore -lStudyStorage -lStudyAssistant -lStudyRuntime -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$build/LanguageNoob" "$root"/Sources/LanguageNoob/*.swift "$build/BundleModule.swift"

"$swiftc" $common -parse-as-library -emit-executable -I "$build" -L "$build" \
  -lStudyCore -lStudyStorage -lStudyAssistant -lStudyRuntime -Xlinker -rpath -Xlinker '@executable_path/../lib' \
  -o "$build/language-noob" "$root"/Sources/LanguageNoobCLI/*.swift

"$swiftc" $common -parse-as-library -emit-executable -I "$build" -L "$build" \
  -lStudyCore -lStudyStorage -lStudyAssistant -lStudyRuntime -Xlinker -rpath -Xlinker "$build" \
  -o "$build/LanguageNoobTests" "$root"/Tests/LanguageNoobTests/*.swift

"$swiftc" $common -parse-as-library -emit-executable -I "$build" -L "$build" \
  -lStudyCore -lStudyStorage -lStudyAssistant -lStudyRuntime -Xlinker -rpath -Xlinker "$build" \
  -o "$build/ApplicationTests" "$root"/Sources/LanguageNoob/AppSettings.swift \
  "$root"/Sources/LanguageNoob/StudyController.swift "$root"/Sources/LanguageNoob/StudyPage.swift \
  "$root"/Sources/LanguageNoob/PaperWindow.swift "$root"/Sources/LanguageNoob/WindowControls.swift \
  "$root"/Tests/ApplicationTests/*.swift

cp "$build/libStudyCore.dylib" "$build/Frameworks/"
cp "$build/libStudyStorage.dylib" "$build/Frameworks/"
cp "$build/libStudyAssistant.dylib" "$build/Frameworks/"
cp "$build/libStudyRuntime.dylib" "$build/Frameworks/"

app="$root/dist/LanguageNoob.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Resources" "$app/Contents/Resources/Vocabulary"
cp "$build/LanguageNoob" "$app/Contents/MacOS/LanguageNoob"
cp "$build/Frameworks/"*.dylib "$app/Contents/Frameworks/"
cp "$root/Sources/LanguageNoob/Resources/"* "$app/Contents/Resources/Resources/"
cp "$root/Sources/StudyRuntime/Resources/"* "$app/Contents/Resources/Vocabulary/"
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"
cli="$root/dist/language-noob"
rm -rf "$cli"
mkdir -p "$cli/bin" "$cli/lib" "$cli/Resources/Vocabulary"
cp "$build/language-noob" "$cli/bin/"
cp "$build/Frameworks/"*.dylib "$cli/lib/"
cp "$root/Sources/StudyRuntime/Resources/"* "$cli/Resources/Vocabulary/"
cp "$root/LICENSE" "$cli/LICENSE"
iconset="$build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$root/Sources/LanguageNoob/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$root/Sources/LanguageNoob/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LanguageNoob</string>
<key>CFBundleIdentifier</key><string>com.language-noob.app</string>
<key>CFBundleName</key><string>Language Noob</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

DYLD_LIBRARY_PATH="$build" "$build/LanguageNoobTests"
DYLD_LIBRARY_PATH="$build" "$build/ApplicationTests"
python3 "$root/Tests/TerminalTests/process_checks.py" "$cli/bin/language-noob"
printf 'PASS: Swift modules, application and tests\nAPP: %s\n' "$app"
printf 'CLI: %s\n' "$cli/bin/language-noob"
