#!/bin/bash
# Firma con Developer ID, notariza y grapa la app, dejándola lista para
# repartir: en el Mac de cualquiera se abre con doble clic, sin avisos ni
# rodeos con `xattr`.
#
# Uso:  ./notarize.sh
#
# Hace falta una vez, antes de la primera ejecución:
#
#   1. Un certificado «Developer ID Application» en el llavero. El de
#      «Apple Development» que usa build.sh NO vale para repartir: sirve para
#      el Mac donde se compiló y en cualquier otro Gatekeeper lo rechaza.
#      Se saca así (sin Xcode):
#        a) Acceso a Llaveros > menú Certificado > Asistente de certificados >
#           «Solicitar un certificado a una autoridad de certificación…».
#           Correo, nombre, «Guardar en disco». Sale un .certSigningRequest.
#        b) developer.apple.com/account/resources/certificates/add >
#           «Developer ID Application» > subir ese archivo > descargar el .cer.
#           (Sólo lo puede crear el titular de la cuenta del equipo.)
#        c) Doble clic en el .cer para meterlo en el llavero.
#
#   2. Las credenciales para notarizar, guardadas en el llavero:
#        xcrun notarytool store-credentials "backupssd" \
#            --apple-id TU_APPLE_ID --team-id JKMR84FU58 \
#            --password CONTRASEÑA_ESPECÍFICA_DE_APP
#      La contraseña específica de app se crea en appleid.apple.com >
#      «Iniciar sesión y seguridad» > «Contraseñas específicas de la app».
#      No es la contraseña normal del Apple ID.

set -euo pipefail
cd "$(dirname "$0")"

APP="Backup SSD"
DEST="build/$APP.app"
PERFIL="${NOTARY_PROFILE:-backupssd}"
VERSION="${1:-1.0}"
ZIP="build/BackupSSD-$VERSION.zip"

# --- 1. ¿Está lo que hace falta? ----------------------------------------
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)

if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'FALTA'
✗ No hay ningún certificado «Developer ID Application» en el llavero.

  Es otro certificado distinto del de «Apple Development», aunque los dos
  salgan de la misma cuenta de pago. Sin él se puede firmar, pero no
  notarizar, y la app sigue sin abrirse en otros Macs.

  Cómo conseguirlo: está explicado arriba, en la cabecera de este script.
  Para ver lo que hay ahora:  security find-identity -v -p codesigning
FALTA
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PERFIL" >/dev/null 2>&1; then
    cat >&2 <<FALTA
✗ No hay credenciales guardadas con el nombre «$PERFIL».

  Guárdalas una vez con:
    xcrun notarytool store-credentials "$PERFIL" \\
        --apple-id TU_APPLE_ID --team-id JKMR84FU58 \\
        --password CONTRASEÑA_ESPECÍFICA_DE_APP
FALTA
    exit 1
fi

echo "Firmando con: $IDENTITY"

# --- 2. Compilar y firmar -----------------------------------------------
# `--options runtime` (hardened runtime) no es opcional: Apple no notariza
# nada que no lo lleve.
./build.sh >/dev/null
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST"
codesign --verify --deep --strict --verbose=2 "$DEST"

# --- 3. Mandarla a notarizar --------------------------------------------
# Se manda un zip, pero el sello se pega luego sobre la app, no sobre el zip.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$DEST" "$ZIP"

echo "Enviando a Apple (esto tarda entre uno y varios minutos)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PERFIL" --wait

# --- 4. Grapar el sello --------------------------------------------------
# Grapar mete el resultado dentro de la propia app, para que valga aunque el
# ordenador que la abra esté sin conexión.
xcrun stapler staple "$DEST"

# --- 5. Volver a empaquetar, ya grapada ----------------------------------
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$DEST" "$ZIP"

echo
echo "Comprobación final —lo que verá el Mac de otra persona:"
spctl -a -vv "$DEST"
echo
echo "Listo para repartir: $ZIP"
