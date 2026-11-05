#!/bin/bash
# Build "Jot.app" (乔木闪记) into ./build.
# Signed with Developer ID + hardened runtime so dev builds and the installed app share one
# Accessibility grant. RELEASE=1 adds a secure timestamp (needed for notarization).
set -euo pipefail
cd "$(dirname "$0")"
NAME="Jot"
NAME_ZH="乔木闪记"
VERSION=$(cat VERSION)
BUILD_NUMBER=$(date +%Y%m%d%H%M)

# Releases are universal (Apple Silicon + Intel); local builds stay native for speed.
ARCHS=(); if [ "${RELEASE:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Jot" "$APP/Contents/MacOS/Jot"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp -R Resources/Icons "$APP/Contents/Resources/Icons"      # simple-icons (CC0) + Lucide (ISC) glyphs
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"    # Kenney Interface Sounds (CC0)
cp -R Resources/AdBlock "$APP/Contents/Resources/AdBlock"    # Peter Lowe ad-server list + CN networks
cp -R Resources/About "$APP/Contents/Resources/About"      # WeChat / reward QR codes
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle; do if [ -e "$b" ]; then cp -R "$b" "$APP/Contents/Resources/"; fi; done

# Sparkle (auto-update): embed the framework and let the binary find it.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Jot" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Jot"
fi

# Icon Composer icon → Assets.car (macOS 26+) and AppIcon.icns (older systems).
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon --target-device mac \
  --output-partial-info-plist build/icon-partial.plist >/dev/null

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>LSHasLocalizedDisplayName</key><true/>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleIdentifier</key><string>ai.qiaomu.ob-helper</string>
<key>CFBundleExecutable</key><string>Jot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 乔木</string>
<key>SUFeedURL</key><string>https://github.com/joeseesun/qiaomu-jot/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>ftyDAv8Qvb8tv4nf5jnMWtCgIi9yVI2IM6p+qhrKz90=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSAppleEventsUsageDescription</key><string>用于读取浏览器当前网页的标题和链接、邮件的主题和链接，作为收录内容的来源。</string>
</dict></plist>
PL

# Localized display name: 乔木闪记 on Chinese systems, Jot elsewhere.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<STR
"CFBundleName" = "$NAME_ZH";
"CFBundleDisplayName" = "$NAME_ZH";
"NSAppleEventsUsageDescription" = "用于读取浏览器当前网页的标题和链接、邮件的主题和链接，作为收录内容的来源。";
STR
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STR
"CFBundleName" = "Jot";
"CFBundleDisplayName" = "Jot";
"NSAppleEventsUsageDescription" = "Reads the current page title and URL from your browser, or the subject and link of a Mail message, to record where a capture came from.";
STR

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
fi
TS="--timestamp=none"; if [ "${RELEASE:-0}" = "1" ]; then TS="--timestamp"; fi
# Sparkle's helpers are signed inside-out before the app (its documented Developer ID order).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc" "$SPK/Autoupdate" "$SPK/Updater.app" \
            "$APP/Contents/Frameworks/Sparkle.framework"; do
  if [ -e "$item" ]; then
    codesign --force --options runtime $TS --preserve-metadata=entitlements --sign "${IDENTITY:--}" "$item"
  fi
done
codesign --force --options runtime $TS --entitlements Resources/Jot.entitlements \
  --sign "${IDENTITY:--}" "$APP"
echo "Built: $APP ($VERSION, signed by ${IDENTITY:-ad-hoc})"
