#!/usr/bin/env bash
# Instala e abre o app na TV pela rede. Uso: ./install.sh IP_DA_TV[:PORTA]
set -euo pipefail
cd "$(dirname "$0")"
[ $# -ge 1 ] || { echo "Uso: ./install.sh IP_DA_TV[:PORTA]   (ex.: ./install.sh 192.168.0.20)"; exit 1; }

TARGET="$1"
[[ "$TARGET" == *:* ]] || TARGET="$TARGET:5555"

[ -f ProjetarTV.apk ] || ./build.sh
adb connect "$TARGET"
adb -s "$TARGET" wait-for-device
adb -s "$TARGET" install -r ProjetarTV.apk
adb -s "$TARGET" shell am start -n br.com.maico.projetartv/.MainActivity
