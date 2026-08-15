// Banco de pruebas del motor: cuánto tarda, y en qué.
//
// Se monta un árbol parecido a lo que tiene cualquiera en su carpeta de
// trabajo —muchos archivos pequeños repartidos en carpetas, unos pocos
// grandes— y se cronometran las tres situaciones que importan:
//
//   1. La primera copia, cuando el disco está vacío.
//   2. La segunda pasada sin tocar nada, que es la que se hará el 95 % de las
//      veces y la que tiene que ser casi instantánea.
//   3. Una pasada con unos pocos archivos cambiados.

import Foundation

let fm = FileManager.default
let total = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20000 : 20000

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("backupssd-bench-\(UUID().uuidString.prefix(8))")
let origen = root.appendingPathComponent("origen")
let disco = root.appendingPathComponent("disco")

func crearArbol() {
    // 50 archivos por carpeta y tres niveles de hondura: se parece más a una
    // carpeta de proyectos de verdad que 20.000 archivos en fila.
    let porCarpeta = 50
    let carpetas = max(1, total / porCarpeta)
    let contenido = String(repeating: "x", count: 2048)

    for c in 0..<carpetas {
        let dir = origen
            .appendingPathComponent("nivel-\(c / 100)")
            .appendingPathComponent("sub-\(c / 10)")
            .appendingPathComponent("carpeta-\(c)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in 0..<porCarpeta {
            try? contenido.write(to: dir.appendingPathComponent("archivo-\(f).txt"),
                                 atomically: false, encoding: .utf8)
        }
    }

    // Unos cuantos grandes, para que el tiempo no sea solo de metadatos.
    let grande = Data(count: 8 * 1024 * 1024)
    let dirG = origen.appendingPathComponent("grandes")
    try? fm.createDirectory(at: dirG, withIntermediateDirectories: true)
    for i in 0..<5 {
        try? grande.write(to: dirG.appendingPathComponent("grande-\(i).bin"))
    }
}

func config() -> Config {
    var c = Config()
    c.volumeUUID = "banco-de-pruebas"
    c.folders = [SyncFolder(source: origen.path, name: "datos")]
    return c
}

func rellenar(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

@discardableResult
func cronometrar(_ nombre: String, _ cuerpo: () -> SyncReport) -> TimeInterval {
    let t0 = Date()
    let r = cuerpo()
    let dt = Date().timeIntervalSince(t0)
    print("  \(rellenar(nombre, 32)) \(String(format: "%7.2f s", dt))   \(r.summary)")
    if r.touched > 0, dt > 0 {
        let ritmo = String(format: "%.0f", Double(r.touched) / dt)
        print("  \(rellenar("", 32))            \(ritmo) archivos/s, \(fmtBytes(r.bytesWritten)) escritos")
    }
    return dt
}

func correr(_ cfg: Config) -> SyncReport {
    let motor = SyncEngine()
    return (try? motor.run(config: cfg, root: disco)) ?? SyncReport()
}

// MARK: - A correr

print("Banco de pruebas — \(total) archivos pequeños + 5 de 8 MB")
print(String(repeating: "─", count: 68))

print("Creando el árbol de prueba…")
try? fm.createDirectory(at: origen, withIntermediateDirectories: true)
try? fm.createDirectory(at: disco, withIntermediateDirectories: true)
let t0 = Date()
crearArbol()
print(String(format: "  (tardó %.1f s en montarlo)\n", Date().timeIntervalSince(t0)))

let cfg = config()

cronometrar("1. Primera copia", { correr(cfg) })
cronometrar("2. Sin cambios (el caso normal)", { correr(cfg) })

// Se cambian 20 archivos sueltos: lo típico de un día de trabajo.
let dirCambios = origen.appendingPathComponent("nivel-0/sub-0/carpeta-0")
for i in 0..<20 {
    try? String(repeating: "y", count: 4096)
        .write(to: dirCambios.appendingPathComponent("archivo-\(i).txt"),
               atomically: false, encoding: .utf8)
}
cronometrar("3. Con 20 archivos cambiados", { correr(cfg) })

// Y se borra una carpeta entera, para medir el apartado a _Retirados.
try? fm.removeItem(at: origen.appendingPathComponent("nivel-0/sub-1"))
cronometrar("4. Con una carpeta borrada", { correr(cfg) })

print(String(repeating: "─", count: 68))
try? fm.removeItem(at: root)
