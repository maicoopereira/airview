# AirView

Usa a Android TV como **segunda tela do Mac pelo Wi‑Fi**, com vídeo e som — como o AirPlay, controlado por um
ícone na barra de menus.

```
Mac (AirView.app, barra de menus)                      Android TV (app AirView)
monitor virtual "AirView"  (Ajustes → Monitores)        serviço leve, liga junto com a TV
saída de som "AirView"     (Ajustes → Som)              anuncia a TV na rede, abre a projeção quando o Mac pede
  → ScreenCaptureKit → H.264 (VideoToolbox)              → MediaCodec (H.264 por hardware) → tela
  → som da saída AirView → PCM                           → AudioTrack → alto-falantes (sincronizado com a imagem)
  ── TCP, cifrado com AES‑256‑GCM, só para a TV pareada ──►
```

- `mac/` — app de barra de menus em Swift (servidor, monitor virtual, captura, segurança).
- `mac/AudioDriver/` — saída de som "AirView" (driver Core Audio baseado no BlackHole, GPL‑3.0).
- `mac/Assets/` — ícone (gerado por `make_icons.swift`).
- `android/` — app da TV (Java, compilado sem Gradle).

## Uso no dia a dia

1. Clique no ícone de TV na barra superior do Mac e escolha a TV em **TVs na rede**.
2. A TV acende e mostra a tela do Mac. O monitor e a saída de som "AirView" aparecem no Mac e o som passa
   para a TV automaticamente.
3. No mesmo menu: **Vídeo** (Estender / Espelhar), **Som** (Na TV / No Mac) e **Desconectar** (⌘D), que fecha a
   projeção, remove o monitor e a saída de som e desliga o servidor.

Não é preciso abrir nada na TV. Resolução e posição do monitor: **Ajustes de Monitores…** no menu.
O volume da TV segue as teclas de volume do Mac quando o som está na TV.

**Primeira vez com uma TV:** o Mac mostra um código de 6 dígitos e a TV mostra o mesmo; aperte **OK** no controle
se forem iguais. Depois disso a TV fica pareada. **Esquecer TVs pareadas** no menu apaga os pareamentos do Mac.

## Instalação

Os comandos abaixo rodam a partir da pasta do projeto.

### Mac

```bash
mac/AudioDriver/install.sh
```

```bash
mac/build-app.sh
```

O primeiro instala a saída de som (pede a senha de administrador); o segundo compila e instala
`~/Applications/AirView.app`. Na primeira vez, libere para o AirView: **Gravação de Tela e Áudio do Sistema**,
**Microfone** (o macOS trata a leitura da saída "AirView" como entrada) e **Rede Local**. No menu dá para ligar
**Abrir ao iniciar sessão**.

O app é assinado com o certificado local **"AirView Local"** (Keychain de login), para as permissões não se
perderem a cada atualização. Registro do app: `~/Library/Logs/AirView.log`.

### Android TV

Precisa do modo desenvolvedor só para instalar (Configurações → Sistema → Sobre → 7 cliques em Build;
depois Opções do desenvolvedor → Depuração USB/de rede):

```bash
android/install.sh IP_DA_TV
```

Depois de instalado, **desligue a depuração por rede** na TV (ver Segurança). O serviço do AirView liga sozinho
quando a TV liga e ocupa ~4 MB de memória.

## Segurança

Pensado para funcionar em redes abertas:

- **Pareamento** com troca de chaves ECDH P‑256; a TV só aceita um Mac novo com OK no controle, conferindo o
  mesmo código nas duas telas (um intermediário na rede geraria códigos diferentes). Chave guardada no Keychain
  do Mac e na área privada do app na TV (sem backup).
- **Comandos assinados** (HMAC‑SHA256 sobre um desafio novo a cada conexão): só Macs pareados controlam a TV, e
  nada gravado pode ser repetido.
- **Transmissão cifrada** com AES‑256‑GCM e chave nova por sessão e por conexão; a TV precisa provar que recebeu
  a chave antes de receber qualquer imagem. O Mac não se anuncia na rede e o servidor só fica ligado durante
  a sessão.
- **Limites**: conexões não autenticadas caem em 3 s; no máximo 4 conversas simultâneas em cada lado; linhas de
  controle até 4 KB; quadros até 16 MB; campos validados.

Bateria de ataques de rede (intruso na mesma rede): espiar a tela, ficar conectado sem autenticar, enxurrada de
conexões no Mac e na TV, comandos sem pareamento, sem assinatura ou repetidos, derrubar a projeção, pareamento com
chave falsa e linha sem fim — todos bloqueados.

**A depuração por rede (adb, porta 5555) da TV deixa qualquer um da rede instalar apps nela.** Use só para
instalar/atualizar o AirView e desligue em seguida (Opções do desenvolvedor → Depuração de rede).

## Recompilar

```bash
android/build.sh
```

```bash
swift mac/Assets/make_icons.swift
```

O segundo regenera os ícones.

Guarde `android/debug.keystore` fora do repositório (está no `.gitignore`): é a chave que assina o app da
TV. Sem ela, a próxima versão exige desinstalar o app da TV e parear de novo.

Para remover a saída de som:

```bash
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/ProjetarTVAudio.driver" && sudo killall coreaudiod
```

## Limitações

- A TV fica ~0,15–0,2 s atrás da tela do Mac (rede + decodificador e som da própria TV); imagem e som da TV saem
  sincronizados entre si. Cabo de rede na TV deixa tudo mais estável que o Wi‑Fi 2,4 GHz.
- O monitor virtual usa uma API privada do macOS (`CGVirtualDisplay`, a mesma do BetterDisplay/DeskPad); uma
  atualização do macOS pode exigir ajuste.
- Android 10 ou mais novo restringe abrir telas a partir do serviço; nesta TV (Android 9) funciona.

## Licença

O AirView é distribuído sob a licença **MIT** (veja `LICENSE`), com uma exceção: a pasta `mac/AudioDriver/`
(a saída de som "AirView") é derivada do [BlackHole](https://github.com/ExistentialAudio/BlackHole) e segue a
**GPL‑3.0** (veja `mac/AudioDriver/LICENSE`). O driver é um programa separado, carregado pelo próprio macOS; o
restante do AirView só conversa com ele pelas interfaces de áudio do sistema.
