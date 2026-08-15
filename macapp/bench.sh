#!/bin/bash
# Mide el motor con muchos archivos, que es donde se nota.
#
# Las pruebas de test.sh dicen si el resultado es correcto; esto dice si tarda
# lo que debe. Se ejecuta sobre carpetas temporales del disco interno, así que
# los números no son los de un SSD por USB —serán mejores—, pero sirven para
# comparar una versión del motor con la siguiente, que es para lo que está.
#
# Uso:  ./bench.sh [nº de archivos]     (por omisión 20000)

set -euo pipefail
cd "$(dirname "$0")"

mkdir -p tests/build

echo "Compilando…"
swiftc \
    -swift-version 5 \
    -O \
    -o tests/build/bench \
    Sources/Config.swift Sources/Localization.swift Sources/SyncEngine.swift Sources/Volumes.swift tests/bench/main.swift

echo
./tests/build/bench "${1:-20000}"
