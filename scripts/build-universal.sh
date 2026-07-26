#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
release_dir="$project_dir/dist"
app_dir="$release_dir/XTerm.app"
arm_bin="$project_dir/.build/arm64-apple-macosx/release/XTerm"
x64_bin="$project_dir/.build/x86_64-apple-macosx/release/XTerm"

cd "$project_dir"
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create "$arm_bin" "$x64_bin" -output "$app_dir/Contents/MacOS/XTerm"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"

echo "Built: $app_dir"
lipo -archs "$app_dir/Contents/MacOS/XTerm"
