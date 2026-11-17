#!/usr/bin/env bash
# Compila o dispositivo de som "AirView" (driver HAL do Core Audio).
# Fonte: BlackHole (https://github.com/ExistentialAudio/BlackHole, GPL-3.0), renomeado — ver LICENSE.
# O dispositivo funciona como loopback: o que o Mac toca nele, o servidor ProjetarTV lê na entrada e manda para a TV.
set -euo pipefail
cd "$(dirname "$0")"

NAME=ProjetarTVAudio
FACTORY_UUID=F80A4A52-6832-427E-90E9-7ED3923EF1B2
OUT="build/$NAME.driver"
rm -rf build
mkdir -p "$OUT/Contents/MacOS"

clang -O2 -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
    -DkDriver_Name='"ProjetarTV"' \
    -DkHas_Driver_Name_Format=false \
    -DkDevice_Name='"AirView"' \
    -DkPlugIn_BundleID='"br.com.maico.projetartv.audio"' \
    -DkManufacturer_Name='"AirView"' \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    -o "$OUT/Contents/MacOS/$NAME" ProjetarTVAudio.c

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>English</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>br.com.maico.projetartv.audio</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AirView</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFPlugInFactories</key>
    <dict><key>$FACTORY_UUID</key><string>AirViewAudio_Create</string></dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array><string>$FACTORY_UUID</string></array>
    </dict>
</dict>
</plist>
EOF

codesign --force --sign - "$OUT"
echo "Driver pronto: $(pwd)/$OUT"
