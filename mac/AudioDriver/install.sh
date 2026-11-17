#!/usr/bin/env bash
# Instala o dispositivo de som "AirView" e reinicia o serviço de áudio do macOS (pede a senha de administrador).
# Para remover: sudo rm -rf "/Library/Audio/Plug-Ins/HAL/ProjetarTVAudio.driver" && sudo killall coreaudiod
set -euo pipefail
cd "$(dirname "$0")"
[ -d build/ProjetarTVAudio.driver ] || ./build.sh

sudo rm -rf /Library/Audio/Plug-Ins/HAL/ProjetarTVAudio.driver
sudo cp -R build/ProjetarTVAudio.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/ProjetarTVAudio.driver
sudo killall coreaudiod
echo "Instalado. \"AirView\" aparece em Ajustes do Sistema → Som → Saída em alguns segundos."
