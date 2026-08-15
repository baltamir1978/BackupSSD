# Backup SSD

Una app de macOS que copia tus carpetas a un SSD externo **en cuanto lo
enchufas**. Vive en la barra de menús, no pide nada, y cuando conectas el disco
de siempre se pone a trabajar sola.

No es Time Machine ni pretende serlo: no hay versiones ni instantáneas. Lo que
hay en el Mac acaba en el disco, tal cual, en carpetas normales que puedes
abrir en cualquier ordenador sin este programa delante.

![El icono de Backup SSD](macapp/Resources/AppIcon-preview.png)

## Lo que hace distinto

**Reconoce el disco por su UUID, nunca por su nombre.** Dos discos pueden
llamarse «Backup», y macOS monta el segundo como «Backup 1». Copiar en el disco
equivocado sería malo; *retirar* del disco equivocado lo que no está en el Mac
sería mucho peor. Antes de escribir un solo byte se vuelve a comprobar que el
volumen montado es el que dice ser.

**Lo que borras en el Mac no se borra del disco.** Se aparta a
`_Retirados/AAAA-MM-DD/`, conservando su ruta, y se borra de verdad pasados N
días (90 por omisión; a 0, nunca). Es la red debajo de un borrado por error, y
es lo que separa esto de un espejo a secas.

**Planifica antes de tocar nada.** Primero mira los dos lados, decide qué hay
que hacer y calcula cuánto espacio hace falta. Sólo entonces escribe. Así se
sabe si cabe antes de empezar, y la barra de progreso significa algo.

**Cada archivo se copia a un temporal y se pone en su sitio al terminar.** Si
el disco se desconecta a media copia, lo que queda es un `.bssd-parcial`
evidente, y no un archivo con el nombre bueno y la mitad del contenido, que es
lo que de verdad hace daño porque parece correcto.

**Se puede parar para desconectar el disco.** «Detener y expulsar» corta la
copia —incluso a mitad de un archivo grande, que se copia por trozos justo para
esto— y desmonta el volumen. Sin tirar del cable.

**Se entera de los archivos que están en uso.** Si alguien está guardando un
archivo mientras se copia, lo que va al disco es medio viejo y medio nuevo. No
hay forma de evitarlo, pero sí de detectarlo: se compara la fecha y el tamaño
antes y después, la copia se marca para rehacerla y se dice en el registro.

## Instalar

### Compilándola (recomendado)

No hace falta Xcode, sólo las Command Line Tools:

```sh
git clone https://github.com/baltamir1978/BackupSSD.git
cd BackupSSD/macapp
./make_icon.sh          # el icono, una sola vez
./build.sh --install    # compila y la deja en /Applications
```

Si tienes un certificado de desarrollador en el llavero, `build.sh` lo usa
solo. Merece la pena: los permisos de privacidad se conceden a una identidad,
así que con firma estable se conceden una vez y no en cada compilación.

### Desde la release

Las releases traen la app ya compilada, firmada con un certificado de
desarrollo de Apple. **Eso vale para el Mac donde se compiló, no para el
tuyo**: Gatekeeper la bloqueará la primera vez, porque distribuirla sin aviso
exige un «Developer ID» de pago y notarización. Para abrirla igualmente:

```sh
xattr -d com.apple.quarantine "/Applications/Backup SSD.app"
```

O clic derecho sobre la app → Abrir → Abrir. Sólo la primera vez.

## Usar

1. Pulsa el icono de la barra de menús → **Ajustes…**
2. Pestaña **Disco**: enchufa el SSD y dale a *Elegir*.
3. Abre la ventana y arrastra las carpetas que quieras copiar.
4. Dale a **Ensayo** antes que a *Sincronizar ahora*: cuenta lo que haría sin
   escribir nada. Con un disco de verdad de por medio, esa primera pasada en
   seco merece la pena.
5. En **General**, activa *Abrir Backup SSD al iniciar sesión*. Sin eso no
   puede enterarse de que has enchufado el disco.

La primera vez macOS pedirá permiso para leer el Escritorio, los Documentos y
las Descargas. Hay que concederlo o no podrá copiarlos.

## La configuración

Vive en `~/.config/backup-ssd/config.json`, no en `UserDefaults`, a propósito:
es un archivo que se puede abrir, leer y corregir con un editor cuando algo va
mal, y copiar a otro Mac sin más ceremonia.

```json
{
  "volumeUUID": "…",           // el disco, por identificador
  "volumeName": "SSD-T7",      // sólo para enseñarlo en la interfaz
  "rootFolder": "Backup-SSD",  // todo cuelga de aquí dentro del disco
  "folders": [ { "source": "/Users/tú/Proyectos", "name": "Proyectos", "enabled": true } ],
  "autoSyncOnMount": true,
  "keepRemoved": true,
  "removedRetentionDays": 90,
  "excludes": [".DS_Store", "node_modules", "*.pyc", "…"],
  "skipUndownloadediCloud": true
}
```

Las exclusiones se comparan con el **nombre** del archivo o de la carpeta, no
con la ruta entera, y admiten un `*` al principio o al final.

`skipUndownloadediCloud` se salta los archivos de iCloud que sólo están en la
nube. Copiarlos obligaría a descargarlos todos primero, que es justo lo que
nadie espera al enchufar un disco.

## Rendimiento

Sobre 20.000 archivos pequeños más 5 de 8 MB, en disco interno
(`macapp/bench.sh`):

| | Antes | Ahora |
|---|---:|---:|
| Primera copia | 5,75 s | **2,47 s** |
| Pasada sin cambios | 2,59 s | **0,38 s** |
| Con una carpeta borrada | 2,62 s | **0,45 s** |

La pasada en la que no cambia nada es la que se hace el 95 % de las veces, y es
la que más se ha ganado. De dónde salió, por orden:

- **Las claves de iCloud de `resourceValues` costaban 18 veces más que todo lo
  demás junto** (0,93 s frente a 0,05 s): no salen del sistema de archivos, van
  a preguntarle al proceso de iCloud una vez por archivo. Ahora sólo se piden
  si la carpeta está de verdad en iCloud.
- Los dos lados se recorren **a la vez**: mientras el Mac contesta, el disco
  externo estaba parado.
- Las copias van en **4 hilos**. Medido: 1 → 4,73 s, 2 → 3,21 s, 4 → 2,49 s,
  8 → 3,55 s, 16 → 3,70 s. Pasado ese punto sólo se consigue que el disco vaya
  y venga entre sitios distintos.
- La profundidad de cada ruta se calcula **una vez** y no dentro del
  comparador del ordenamiento, que la pedía unas 300.000 veces para averiguar
  20.000 datos.

## Para trastear con el código

```sh
cd macapp
./test.sh            # 90 comprobaciones sobre carpetas temporales
./bench.sh 20000     # cuánto tarda, y en qué
./check_strings.py   # las traducciones contra el código
./build.sh --run     # compilar y abrir
```

El motor (`SyncEngine.swift`), la configuración (`Config.swift`) y la lectura
de discos (`Volumes.swift`) no dependen de SwiftUI ni de AppKit **a propósito**:
así se compilan y se prueban desde la terminal en segundos, que es la única
forma sensata de fiarse de un programa que borra archivos. Las pruebas corren
sobre carpetas temporales; no hace falta enchufar ningún disco.

| Archivo | Qué es |
|---|---|
| `Sources/SyncEngine.swift` | El motor: comparar, planificar, copiar, retirar. |
| `Sources/Config.swift` | Qué se copia y con qué reglas. |
| `Sources/Volumes.swift` | Los discos montados, vistos por UUID. |
| `Sources/VolumeWatcher.swift` | Enterarse de que han enchufado el disco. |
| `Sources/AppState.swift` | Decide *cuándo* se sincroniza. |
| `Sources/App.swift` + `*View.swift` | La interfaz. |
| `Sources/LoginItem.swift` | Arrancar al iniciar sesión (un LaunchAgent). |

### Idiomas

Español (base), inglés y francés, en `macapp/Resources/*.lproj`. La clave de
cada cadena es la frase en español: si falta una traducción sale español, nunca
un identificador. `./check_strings.py` avisa de lo que falta y de lo que sobra.

Para probar un idioma sin cambiar el del Mac:

```sh
open "build/Backup SSD.app" --args -AppleLanguages '(fr)'
defaults delete es.backupssd.app AppleLanguages   # ← macOS lo recuerda; hay que borrarlo
```

## Todavía no

- **Un destino distinto por carpeta.** Hoy cada carpeta va a
  `<raíz>/<nombre>`, y el nombre es un solo componente. La idea es poder decir
  a qué subcarpeta del disco va cada origen, con la condición de no permitir
  combinaciones que se aniden entre sí: si un destino cae dentro de otro, la
  carpeta de fuera «retiraría» los archivos de la de dentro por no encontrarlos
  en su propio origen.
- Notarizar la app para que se abra en otros Macs sin el rodeo del `xattr`.
- Comprobar el contenido y no sólo tamaño y fecha, para quien quiera pagar esa
  lentitud a cambio de estar seguro del todo.

## Licencia

MIT.
