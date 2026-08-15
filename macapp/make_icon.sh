#!/bin/bash
# Genera Resources/AppIcon.icns a partir del SVG que lleva aquí dentro.
#
# El dibujo va en este script y no en un archivo suelto para que el icono se
# pueda cambiar tocando una sola cosa. Se rasteriza con qlmanage, que viene con
# macOS: nada que instalar.
#
# Uso:  ./make_icon.sh

set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Un disco externo con una flecha de sincronización. Se lee a 16 px, que es
# donde de verdad se ve un icono la mayor parte del tiempo.
cat > "$TMP/icon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="fondo" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3E8BFF"/>
      <stop offset="1" stop-color="#1B54C8"/>
    </linearGradient>
    <linearGradient id="cuerpo" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#DCE6F5"/>
    </linearGradient>
  </defs>

  <rect x="64" y="64" width="896" height="896" rx="200" fill="url(#fondo)"/>

  <!-- El disco -->
  <rect x="212" y="392" width="600" height="240" rx="48" fill="url(#cuerpo)"/>
  <circle cx="716" cy="512" r="34" fill="#3E8BFF"/>
  <rect x="272" y="486" width="300" height="18" rx="9" fill="#B9C9E0"/>
  <rect x="272" y="536" width="190" height="18" rx="9" fill="#B9C9E0"/>

  <!-- La flecha: entra en el disco -->
  <path d="M512 168 v112 h-70 l104 116 104-116 h-70 V168 z" fill="#FFFFFF"/>
  <rect x="380" y="716" width="264" height="26" rx="13" fill="#FFFFFF" opacity="0.75"/>
  <rect x="440" y="784" width="144" height="26" rx="13" fill="#FFFFFF" opacity="0.5"/>
</svg>
SVG

echo "Rasterizando…"
qlmanage -t -s 1024 -o "$TMP" "$TMP/icon.svg" >/dev/null 2>&1
BASE="$TMP/icon.svg.png"
[[ -f "$BASE" ]] || { echo "No se pudo rasterizar el SVG."; exit 1; }

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size        "$BASE" --out "$SET/icon_${size}x${size}.png"      >/dev/null
    sips -z $((size*2)) $((size*2)) "$BASE" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$BASE" Resources/AppIcon-preview.png

echo "Listo: Resources/AppIcon.icns"
