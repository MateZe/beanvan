#!/bin/zsh
set -euo pipefail

configuration="${1:-debug}"
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
info_plist="$project_dir/Support/Info.plist"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 64
fi

plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
plist_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
version="${BEANVAN_VERSION:-$plist_version}"
build_number="${BEANVAN_BUILD_NUMBER:-$plist_build_number}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "BEANVAN_VERSION must use the numeric x.y.z format (received: $version)" >&2
    exit 64
fi

if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    echo "BEANVAN_BUILD_NUMBER must be a positive integer (received: $build_number)" >&2
    exit 64
fi

make -C "$project_dir" icon >/dev/null
cd "$project_dir"
swift build -c "$configuration" --product Beanvan

binary_dir="$(swift build -c "$configuration" --show-bin-path)"
binary_path="$binary_dir/Beanvan"
resource_bundle_path="$binary_dir/Beanvan_Beanvan.bundle"
app_path="$project_dir/dist/Beanvan.app"

if [[ ! -d "$resource_bundle_path" ]]; then
    echo "SwiftPM resource bundle not found: $resource_bundle_path" >&2
    exit 66
fi

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/Beanvan"
cp "$info_plist" "$app_path/Contents/Info.plist"
cp "$project_dir/dist/icon-build/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp -R "$resource_bundle_path" "$app_path/Contents/Resources/Beanvan_Beanvan.bundle"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"

# Ad-hoc signing requires no Apple Developer account. Signing after all files
# are assembled seals the resources and enables the hardened runtime.
codesign --force --options runtime --sign - "$app_path"

echo "$app_path"
