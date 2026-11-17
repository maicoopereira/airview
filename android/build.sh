#!/usr/bin/env bash
# Compila o APK sem Gradle, só com as ferramentas do Android SDK (aapt2, javac, d8, apksigner).
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
ANDROID_JAR="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)/android.jar"
# build-tools 34 precisa de Java 17+; o JAVA_HOME do sistema pode apontar para o Java 8.
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export PATH="$JAVA_HOME/bin:$PATH"

OUT=build
rm -rf "$OUT"
mkdir -p "$OUT/res" "$OUT/gen" "$OUT/classes" "$OUT/dex"

"$BUILD_TOOLS/aapt2" compile --dir res -o "$OUT/res/"
"$BUILD_TOOLS/aapt2" link -o "$OUT/unsigned.apk" -I "$ANDROID_JAR" \
    --manifest AndroidManifest.xml --java "$OUT/gen" "$OUT"/res/*.flat

javac --release 8 -nowarn -classpath "$ANDROID_JAR" -d "$OUT/classes" \
    $(find src "$OUT/gen" -name '*.java')

"$BUILD_TOOLS/d8" --release --min-api 21 --lib "$ANDROID_JAR" --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && zip -q ../unsigned.apk classes.dex)

"$BUILD_TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# Chave local só para assinar este app (fica fora de qualquer loja).
if [ ! -f debug.keystore ]; then
    keytool -genkeypair -keystore debug.keystore -storepass android -keypass android -alias projetartv \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=AirView" >/dev/null 2>&1
fi
"$BUILD_TOOLS/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
    --out ProjetarTV.apk "$OUT/aligned.apk"

echo "APK pronto: $(pwd)/ProjetarTV.apk"
