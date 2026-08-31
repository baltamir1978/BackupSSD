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

# El mismo SSD portátil que dibuja la app por dentro (ver DiscoIcon.swift):
# cuerpo apaisado de goma con el nervado en diagonal, la esquina del ojal y el
# punto de luz encendido. Encima, la flecha que entra: es lo que distingue esto
# de un icono de «disco» a secas y dice que aquí las cosas van hacia el disco.
#
# Se lee a 16 px, que es donde de verdad se ve un icono la mayor parte del
# tiempo: a ese tamaño quedan la silueta apaisada, la flecha y el punto verde.
cat > "$TMP/icon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="fondo" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="#2E6CF6"/>
      <stop offset="0.55" stop-color="#1B4BC8"/>
      <stop offset="1" stop-color="#12308A"/>
    </linearGradient>
    <linearGradient id="cuerpo" x1="0.1" y1="0" x2="0.9" y2="1">
      <stop offset="0" stop-color="#4A4E55"/>
      <stop offset="0.55" stop-color="#26292E"/>
      <stop offset="1" stop-color="#15171A"/>
    </linearGradient>
    <linearGradient id="reflejo" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.30"/>
      <stop offset="0.42" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.20"/>
    </linearGradient>
    <linearGradient id="luz" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#8CF7A4"/>
      <stop offset="1" stop-color="#2FBE55"/>
    </linearGradient>
    <radialGradient id="sombra" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#000000" stop-opacity="0.38"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0"/>
    </radialGradient>
    <!-- El nervado de goma, en diagonal y muy fino: a tamaño pequeño tiene
         que insinuarse, no rayar el disco. -->
    <pattern id="nervios" width="40" height="40" patternUnits="userSpaceOnUse"
             patternTransform="rotate(-45)">
      <rect width="9" height="40" fill="#FFFFFF" opacity="0.05"/>
    </pattern>
    <!-- El ojal se recorta de verdad para que se vea el fondo a través. -->
    <mask id="ojal">
      <rect x="0" y="0" width="1024" height="1024" fill="white"/>
      <circle cx="286" cy="466" r="38" fill="black"/>
    </mask>
  </defs>

  <rect x="64" y="64" width="896" height="896" rx="200" fill="url(#fondo)"/>

  <!-- La flecha, entrando en el disco. -->
  <path d="M512 160 v146 h-84 l118 126 118-126 h-84 V160 z" fill="#FFFFFF" opacity="0.95"/>

  <!-- La sombra sobre la que apoya. -->
  <ellipse cx="512" cy="748" rx="290" ry="46" fill="url(#sombra)"/>

  <!-- El disco -->
  <g mask="url(#ojal)">
    <rect x="212" y="396" width="600" height="300" rx="92" fill="url(#cuerpo)"/>
    <rect x="212" y="396" width="600" height="300" rx="92" fill="url(#nervios)"/>
    <rect x="212" y="396" width="600" height="300" rx="92" fill="url(#reflejo)"/>
    <rect x="218" y="402" width="588" height="288" rx="88" fill="none"
          stroke="#FFFFFF" stroke-opacity="0.20" stroke-width="9"/>
  </g>
  <circle cx="716" cy="636" r="24" fill="url(#luz)"/>
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
