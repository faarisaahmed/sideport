#!/bin/zsh
# Builds Sideport.app into ./build.
#   ./build.sh            build
#   ./build.sh --install  build and copy to ~/Applications
#   ./build.sh --release  universal (Apple silicon + Intel) build, zipped into build/ for a GitHub release
#                         (needs rustup with the x86_64-apple-darwin and aarch64-apple-darwin targets)
set -euo pipefail
HERE=${0:A:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACOSX_DEPLOYMENT_TARGET=13.0
APP=$HERE/build/Sideport.app
MODE=${1:-}
mkdir -p $HERE/build

print -P "%F{cyan}==>%f Engine"
if [[ $MODE == --release ]]; then
  export PATH=$HOME/.cargo/bin:$PATH
  (cd $HERE/engine && for t in aarch64-apple-darwin x86_64-apple-darwin; do cargo build --release --quiet --target $t; done)
  ENGINE=$HERE/build/sideport-engine
  lipo -create -output $ENGINE $HERE/engine/target/{aarch64,x86_64}-apple-darwin/release/sideport-engine
  ARCHS=(--arch arm64 --arch x86_64)
else
  (cd $HERE/engine && cargo build --release --quiet)
  ENGINE=$HERE/engine/target/release/sideport-engine
  ARCHS=()
fi
print -P "%F{cyan}==>%f App"
(cd $HERE/app && swift build -c release $ARCHS >$HERE/build/swift.log 2>&1) || { grep -E "error" $HERE/build/swift.log | head -20; print "app build failed"; exit 1; }
BIN=$(cd $HERE/app && swift build -c release $ARCHS --show-bin-path)/Sideport
[[ -x $BIN ]] || { print "app build failed"; exit 1; }

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Sideport
cp $ENGINE $APP/Contents/Resources/sideport-engine
if [[ ! -f $HERE/build/AppIcon.icns ]]; then
  swift $HERE/tools/make_icon.swift $HERE/build/AppIcon.iconset
  iconutil -c icns $HERE/build/AppIcon.iconset -o $HERE/build/AppIcon.icns
fi
cp $HERE/build/AppIcon.icns $APP/Contents/Resources/
VERSION=$(grep '^version' $HERE/engine/Cargo.toml | head -1 | cut -d'"' -f2)
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sideport</string>
  <key>CFBundleDisplayName</key><string>Sideport</string>
  <key>CFBundleIdentifier</key><string>com.faaris.sideport</string>
  <key>CFBundleExecutable</key><string>Sideport</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>iOS App</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>com.apple.itunes.ipa</string></array>
    <key>CFBundleTypeExtensions</key><array><string>ipa</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - $APP/Contents/Resources/sideport-engine $APP >/dev/null 2>&1
print -P "%F{green}Built:%f $APP"
if [[ $MODE == --release ]]; then
  ZIP=$HERE/build/Sideport-$VERSION.zip
  rm -f $ZIP
  ditto -c -k --keepParent $APP $ZIP
  print -P "%F{green}Release:%f $ZIP"
fi
if [[ $MODE == --install ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Sideport.app && cp -R $APP ~/Applications/ && print "Installed to ~/Applications/Sideport.app"
  mdimport ~/Applications/Sideport.app 2>/dev/null || true
fi
