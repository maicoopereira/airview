#!/usr/bin/env bash
# Monta o AirView.app (barra de menus) e instala em ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release

APP="build/AirView.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ProjetarTV "$APP/Contents/MacOS/AirView"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AirView</string>
    <key>CFBundleDisplayName</key><string>AirView</string>
    <key>CFBundleExecutable</key><string>AirView</string>
    <key>CFBundleIdentifier</key><string>br.com.maico.airview</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>O AirView lê o som da saída "AirView" para tocar na TV.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>O AirView procura as TVs da sua rede e transmite a tela para elas.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_projetartv-tv._tcp</string>
    </array>
</dict>
</plist>
PLIST
# Assinatura estável ("AirView Local", certificado do Keychain) mantém as permissões de Gravação de Tela e
# Microfone entre atualizações; sem ela, assinatura ad hoc (o macOS pede as permissões de novo a cada build).
IDENTITY=$(security find-identity -p codesigning | awk '/"AirView Local"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/AirView.app"
cp -R "$APP" "$HOME/Applications/AirView.app"
echo "Instalado: $HOME/Applications/AirView.app"
