#!/bin/bash
# Compila «Backup SSD.app». Sin Xcode: sólo las Command Line Tools.
#
# Uso:  ./build.sh            compila en build/
#       ./build.sh --install  compila y la deja en /Applications
#       ./build.sh --run      compila y la abre
#
# No se firma con una identidad de desarrollador porque no hace falta para
# usarla uno mismo. macOS pedirá permiso la primera vez que la app quiera leer
# el Escritorio, los Documentos o las Descargas: es el aviso normal de
# privacidad, y hay que decir que sí para que pueda copiarlos.

set -euo pipefail
cd "$(dirname "$0")"

APP="Backup SSD"
BUNDLE_ID="es.backupssd.app"
VERSION="1.0"
MIN_MACOS="13.0"

BUILD="build"
DEST="$BUILD/$APP.app"
CONTENTS="$DEST/Contents"

rm -rf "$DEST"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# El icono se genera aparte y puede no estar: la app funciona igual sin él.
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "· No hay icono todavía; ejecuta ./make_icon.sh si lo quieres."
else
    cp Resources/AppIcon.icns "$CONTENTS/Resources/"
fi

# Multilenguaje: se copia cada .lproj que haya en Resources. El idioma base es
# el español —los literales del código son las claves—, así que una clave sin
# traducir cae de vuelta al original en lugar de salir en crudo.
for lproj in Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    cp -R "$lproj" "$CONTENTS/Resources/"
done
# El .lproj del idioma base tiene que existir aunque sólo lleve los plurales:
# sin él macOS no ofrece la app en español en Ajustes > Idioma.
mkdir -p "$CONTENTS/Resources/es.lproj"

echo "Compilando…"
# Una sola llamada con todos los archivos: sin módulos ni enlazado por partes,
# que para ocho archivos sobra y sólo añade cosas que se pueden romper.
swiftc \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -target "arm64-apple-macos$MIN_MACOS" \
    -o "$CONTENTS/MacOS/BackupSSD" \
    Sources/*.swift

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP</string>
    <key>CFBundleDisplayName</key>       <string>$APP</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>        <string>BackupSSD</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>$MIN_MACOS</string>
    <key>CFBundleDevelopmentRegion</key> <string>es</string>
    <!-- El idioma base va primero. Sin esta lista macOS no ofrece la app en
         Ajustes > Idioma y región > Idioma preferido, aunque los .lproj
         estén dentro del bundle. -->
    <key>CFBundleLocalizations</key>
    <array>
        <string>es</string>
        <string>en</string>
        <string>fr</string>
    </array>
    <!-- Vive en la barra de menús: sin icono en el Dock mientras no haya ventana. -->
    <key>LSUIElement</key>               <true/>
    <!-- Lo que macOS enseñará al pedir permiso para leer estas carpetas. -->
    <key>NSDesktopFolderUsageDescription</key>
    <string>Para copiar el Escritorio al disco de backup.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Para copiar los Documentos al disco de backup.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Para copiar las Descargas al disco de backup.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Para escribir la copia en el disco externo.</string>
</dict>
</plist>
PLIST

# Firma.
#
# Se prefiere un certificado de desarrollador a la firma ad-hoc por un motivo
# muy concreto: los permisos de privacidad —leer el Escritorio, los Documentos,
# las Descargas, escribir en discos externos— se conceden a una identidad, no a
# una ruta. Con firma ad-hoc cada compilación produce una identidad distinta y
# macOS vuelve a preguntar; con un certificado estable, se concede una vez y
# sigue valiendo.
#
# Ojo: «Apple Development» vale para este Mac, no para repartir la app. Para
# que se abra sin más en el ordenador de otra persona hace falta un «Developer
# ID Application» (Apple Developer Program, de pago) y notarizarla.
#
# El `|| true` no es adorno: con `set -o pipefail`, un grep que no encuentra
# nada devuelve 1 y abortaría la compilación entera por no tener certificado.
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -o "\"$1: [^\"]*\"" | head -1 | tr -d '"' || true
}

IDENTITY=$(find_identity "Developer ID Application")
[[ -n "$IDENTITY" ]] || IDENTITY=$(find_identity "Apple Development")

# La firma con certificado es obligatoria, no un extra: sin ella los permisos
# de privacidad se vuelven a pedir en cada compilación, y una app de backup a
# la que el sistema deja de reconocer es una app que un día no copia nada.
#
# Quien clone el repositorio y no tenga certificado puede compilar igual con
# ALLOW_ADHOC=1, asumiendo justamente eso.
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --sign "$IDENTITY" "$DEST"
    echo "Firmada con: $IDENTITY"
elif [[ "${ALLOW_ADHOC:-}" == "1" ]]; then
    codesign --force --sign - "$DEST" 2>/dev/null
    echo "Firmada ad-hoc (sin certificado): macOS volverá a pedirte permiso"
    echo "sobre tus carpetas después de cada compilación."
else
    echo "✗ No hay ningún certificado de firma en el llavero." >&2
    echo "  Se buscó «Developer ID Application» y «Apple Development»." >&2
    echo "  Míralo con:  security find-identity -v -p codesigning" >&2
    echo "  Para compilar sin firmar de todos modos:  ALLOW_ADHOC=1 ./build.sh" >&2
    exit 1
fi

echo "Listo: $DEST"

case "${1:-}" in
    --install)
        rm -rf "/Applications/$APP.app"
        cp -R "$DEST" /Applications/
        echo "Instalada en /Applications/$APP.app"
        ;;
    --run)
        # Se cierra la que hubiera abierta: si no, `open` se limita a traer al
        # frente la versión vieja y parece que los cambios no han entrado.
        osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
        sleep 1
        open "$DEST"
        ;;
esac
