#!/bin/zsh
set -eu
cd "$(dirname "$0")"
: "${NAGA_SIGNING_IDENTITY:?请设置你自己的代码签名身份}"
NAGA_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/naga-build.XXXXXX")
NAGA_APP="$NAGA_STAGE/小娜迦.app"
mkdir -p "$NAGA_APP/Contents/MacOS" dist
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 -module-cache-path "$NAGA_STAGE/cache" Sources/GoogleRemoteMac/*.swift -o "$NAGA_APP/Contents/MacOS/GoogleRemoteMac"
cp Info.plist "$NAGA_APP/Contents/Info.plist"
ditto --noextattr --norsrc Resources "$NAGA_APP/Contents/Resources"
codesign --force --sign "$NAGA_SIGNING_IDENTITY" "$NAGA_APP"
codesign --verify --deep --strict "$NAGA_APP"
ditto -c -k --sequesterRsrc --keepParent "$NAGA_APP" dist/Naga-Siren-0.9.14.zip
print "已生成 dist/Naga-Siren-0.9.14.zip"
