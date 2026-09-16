#!/bin/bash
# Compila y ejecuta las pruebas del motor.
#
# El motor (SyncEngine.swift), la configuración (Config.swift) y la lectura de
# los discos montados (Volumes.swift) no dependen de SwiftUI ni de AppKit
# precisamente para esto: se compilan solos, en segundos, y las pruebas corren
# sobre carpetas temporales sin necesidad de enchufar ningún disco.
#
# Lo que sí necesita AppKit —VolumeWatcher y la interfaz— se queda fuera: eso
# se prueba enchufando el disco de verdad.
#
# Companions.swift entra aunque hable con AppKit para buscar apps instaladas:
# es donde viven las reglas que `Config` guarda por disco, y sin él la
# configuración no compila. Las pruebas no ejecutan nada de él.
#
# Uso:  ./test.sh

set -euo pipefail
cd "$(dirname "$0")"

mkdir -p tests/build

echo "Compilando las pruebas…"
swiftc \
    -swift-version 6 \
    -o tests/build/tests \
    Sources/Companions.swift Sources/Config.swift Sources/History.swift Sources/Localization.swift Sources/SyncEngine.swift Sources/Volumes.swift tests/main.swift

echo
./tests/build/tests
