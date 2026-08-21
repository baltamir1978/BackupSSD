// Pruebas del motor, sin Xcode ni XCTest: se compilan y se ejecutan con
// ./test.sh.
//
// El motor decide qué archivos se copian y, sobre todo, cuáles se retiran del
// disco. Eso no se prueba «a ojo» con el disco de verdad enchufado: se prueba
// aquí, sobre carpetas de mentira que se crean y se borran en cada pasada.

import Foundation

// MARK: - Andamiaje

var pasadas = 0
var fallos: [String] = []

func check(_ cond: Bool, _ what: String) {
    if cond { pasadas += 1; print("  ✓ \(what)") }
    else { fallos.append(what); print("  ✗ \(what)") }
}

func checkEq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    if a == b { pasadas += 1; print("  ✓ \(what)") }
    else { fallos.append("\(what) — esperaba \(b), llegó \(a)"); print("  ✗ \(what) — esperaba \(b), llegó \(a)") }
}

let fm = FileManager.default

/// Una zona de pruebas nueva por test, que se borra al terminar.
final class Sandbox {
    let root: URL
    var origen: URL { root.appendingPathComponent("origen") }
    var disco: URL { root.appendingPathComponent("disco") }

    init(_ nombre: String) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backupssd-tests/\(nombre)-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: origen, withIntermediateDirectories: true)
        try? fm.createDirectory(at: disco, withIntermediateDirectories: true)
    }
    deinit { try? fm.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, _ texto: String, in base: URL? = nil) -> URL {
        let url = (base ?? origen).appendingPathComponent(rel)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? texto.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func mkdir(_ rel: String, in base: URL? = nil) {
        try? fm.createDirectory(at: (base ?? origen).appendingPathComponent(rel),
                                withIntermediateDirectories: true)
    }

    func exists(_ rel: String, in base: URL? = nil) -> Bool {
        fm.fileExists(atPath: (base ?? disco).appendingPathComponent(rel).path)
    }

    func read(_ rel: String, in base: URL? = nil) -> String? {
        try? String(contentsOf: (base ?? disco).appendingPathComponent(rel), encoding: .utf8)
    }

    /// Config apuntando a este sandbox, con una sola carpeta llamada «datos».
    func config(keepRemoved: Bool = true, excludes: [String]? = nil, retention: Int = 90) -> Config {
        var c = Config()
        c.volumeUUID = "de-mentira"
        c.folders = [SyncFolder(source: origen.path, name: "datos")]
        c.keepRemoved = keepRemoved
        c.removedRetentionDays = retention
        if let e = excludes { c.excludes = e }
        return c
    }
}

func run(_ sb: Sandbox, _ cfg: Config, dryRun: Bool = false) -> SyncReport {
    let motor = SyncEngine()
    do { return try motor.run(config: cfg, root: sb.disco, dryRun: dryRun) }
    catch { fallos.append("lanzó \(error)"); print("  ✗ lanzó \(error)"); return SyncReport() }
}

let hoy = SyncEngine.today()

func test(_ nombre: String, _ cuerpo: () -> Void) {
    print("\n▸ \(nombre)")
    cuerpo()
}

// MARK: - Pruebas

test("Copia inicial: el disco acaba igual que el Mac") {
    let sb = Sandbox("inicial")
    sb.write("nota.txt", "hola")
    sb.write("sub/otro.txt", "adiós")
    sb.write("sub/hondo/tercero.txt", "3")

    let r = run(sb, sb.config())
    checkEq(r.copied, 3, "copia los tres archivos")
    checkEq(r.updated, 0, "no actualiza nada")
    checkEq(r.errors.count, 0, "sin errores")
    check(sb.exists("datos/nota.txt"), "nota.txt está en el disco")
    check(sb.exists("datos/sub/hondo/tercero.txt"), "respeta la jerarquía de carpetas")
    checkEq(sb.read("datos/sub/otro.txt"), "adiós", "el contenido llega entero")
}

test("Segunda pasada sin cambios: no vuelve a copiar nada") {
    let sb = Sandbox("sincambios")
    sb.write("a.txt", "1")
    sb.write("b/c.txt", "2")
    _ = run(sb, sb.config())

    let r = run(sb, sb.config())
    checkEq(r.copied, 0, "no copia de nuevo")
    checkEq(r.updated, 0, "no actualiza de nuevo")
    checkEq(r.retired, 0, "no retira nada")
    checkEq(r.bytesWritten, 0, "no escribe ni un byte")
}

test("Un archivo cambia: se actualiza sólo ese") {
    let sb = Sandbox("cambio")
    sb.write("a.txt", "viejo")
    sb.write("b.txt", "igual")
    _ = run(sb, sb.config())

    // Fecha explícita muy posterior: dentro de la tolerancia de 2 s no se
    // consideraría distinto, y el test dependería de lo rápido que sea el Mac.
    let a = sb.write("a.txt", "nuevo y más largo")
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: a.path)

    let r = run(sb, sb.config())
    checkEq(r.updated, 1, "actualiza uno")
    checkEq(r.copied, 0, "no cuenta ninguno como nuevo")
    checkEq(sb.read("datos/a.txt"), "nuevo y más largo", "el disco tiene la versión nueva")
}

test("Mismo tamaño pero fecha nueva: también se actualiza") {
    let sb = Sandbox("mismotam")
    sb.write("a.txt", "AAAA")
    _ = run(sb, sb.config())

    let a = sb.write("a.txt", "BBBB")     // mismo tamaño exacto
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: a.path)

    let r = run(sb, sb.config())
    checkEq(r.updated, 1, "no se fía sólo del tamaño")
    checkEq(sb.read("datos/a.txt"), "BBBB", "el contenido nuevo llega")
}

test("Borrar en el Mac: la copia se aparta, no se pierde") {
    let sb = Sandbox("retirar")
    sb.write("importante.txt", "no me borres del todo")
    sb.write("queda.txt", "yo me quedo")
    _ = run(sb, sb.config())

    try? fm.removeItem(at: sb.origen.appendingPathComponent("importante.txt"))
    let r = run(sb, sb.config())

    checkEq(r.retired, 1, "retira uno")
    check(!sb.exists("datos/importante.txt"), "ya no está en su sitio")
    check(sb.exists("_Retirados/\(hoy)/datos/importante.txt"), "está en _Retirados, con la fecha")
    checkEq(sb.read("_Retirados/\(hoy)/datos/importante.txt"), "no me borres del todo",
            "y se puede recuperar entero")
    check(sb.exists("datos/queda.txt"), "no toca lo que sigue existiendo")
}

test("Borrar una carpeta entera: se aparta de una pieza") {
    let sb = Sandbox("retirardir")
    sb.write("proyecto/uno.txt", "1")
    sb.write("proyecto/dos.txt", "2")
    sb.write("proyecto/sub/tres.txt", "3")
    _ = run(sb, sb.config())

    try? fm.removeItem(at: sb.origen.appendingPathComponent("proyecto"))
    let r = run(sb, sb.config())

    check(!sb.exists("datos/proyecto"), "la carpeta desaparece del sitio bueno")
    check(sb.exists("_Retirados/\(hoy)/datos/proyecto/uno.txt"), "los archivos están en _Retirados")
    check(sb.exists("_Retirados/\(hoy)/datos/proyecto/sub/tres.txt"), "con su estructura")
    check(!sb.exists("_Retirados/\(hoy)/datos/proyecto-2"),
          "sin partir la carpeta en «proyecto» y «proyecto-2»")
    checkEq(r.errors.count, 0, "sin errores")
}

test("Sin papelera: borrar es borrar") {
    let sb = Sandbox("sinpapelera")
    sb.write("efimero.txt", "x")
    _ = run(sb, sb.config(keepRemoved: false))

    try? fm.removeItem(at: sb.origen.appendingPathComponent("efimero.txt"))
    let r = run(sb, sb.config(keepRemoved: false))

    checkEq(r.retired, 1, "lo retira")
    check(!sb.exists("datos/efimero.txt"), "ya no está")
    check(!sb.exists("_Retirados"), "y no se crea ninguna papelera")
}

test("Lo excluido no se copia") {
    let sb = Sandbox("excluir")
    sb.write("bueno.txt", "sí")
    sb.write(".DS_Store", "basura")
    sb.write("cosas.pyc", "basura")
    sb.write("node_modules/lib/x.js", "muchísima basura")
    sb.write("codigo/main.swift", "sí")

    let r = run(sb, sb.config())
    check(sb.exists("datos/bueno.txt"), "copia lo normal")
    check(sb.exists("datos/codigo/main.swift"), "copia dentro de las carpetas")
    check(!sb.exists("datos/.DS_Store"), "salta .DS_Store")
    check(!sb.exists("datos/cosas.pyc"), "salta *.pyc por su terminación")
    check(!sb.exists("datos/node_modules"), "no entra en node_modules")
    checkEq(r.copied, 2, "sólo cuenta los dos buenos")
}

test("Los enlaces simbólicos se recrean, no se siguen") {
    let sb = Sandbox("enlaces")
    sb.write("real.txt", "contenido")
    try? fm.createSymbolicLink(atPath: sb.origen.appendingPathComponent("atajo.txt").path,
                               withDestinationPath: "real.txt")
    try? fm.createSymbolicLink(atPath: sb.origen.appendingPathComponent("roto.txt").path,
                               withDestinationPath: "no-existe.txt")

    let r = run(sb, sb.config())
    let atajo = sb.disco.appendingPathComponent("datos/atajo.txt").path
    let destino = try? fm.destinationOfSymbolicLink(atPath: atajo)
    checkEq(destino, "real.txt", "el enlace llega como enlace, apuntando a lo mismo")
    check(fm.fileExists(atPath: sb.disco.appendingPathComponent("datos/roto.txt").path)
          || (try? fm.attributesOfItem(atPath: sb.disco.appendingPathComponent("datos/roto.txt").path)) != nil,
          "un enlace roto también se copia, sin dar error")
    checkEq(r.errors.count, 0, "sin errores")
}

test("Un enlace a una carpeta se copia como enlace, sin entrar dentro") {
    let sb = Sandbox("enlace-dir")
    sb.write("real/dentro.txt", "contenido")
    try? fm.createSymbolicLink(atPath: sb.origen.appendingPathComponent("atajo").path,
                               withDestinationPath: "real")

    let r = run(sb, sb.config())
    checkEq(r.errors.count, 0, "sin errores")
    let atajo = sb.disco.appendingPathComponent("datos/atajo").path
    checkEq(try? fm.destinationOfSymbolicLink(atPath: atajo), "real", "llega como enlace")
    check(sb.exists("datos/real/dentro.txt"), "la carpeta de verdad sí se copia")
}

// El enlace se borra en el Mac, pero la carpeta a la que apunta se queda. Si
// al retirarlo se le tratara como carpeta —`fileExists` sigue los enlaces—, se
// llevaría a _Retirados los archivos del otro lado, que no sobran.
test("Retirar un enlace a una carpeta no se lleva por delante lo que hay al otro lado") {
    let sb = Sandbox("retirar-enlace-dir")
    sb.write("real/dentro.txt", "contenido")
    try? fm.createSymbolicLink(atPath: sb.origen.appendingPathComponent("atajo").path,
                               withDestinationPath: "real")
    _ = run(sb, sb.config())

    try? fm.removeItem(at: sb.origen.appendingPathComponent("atajo"))
    let r = run(sb, sb.config())

    checkEq(r.errors.count, 0, "sin errores")
    check(sb.read("datos/real/dentro.txt") == "contenido", "lo apuntado sigue en su sitio")
    check((try? fm.attributesOfItem(atPath: sb.disco.appendingPathComponent("datos/atajo").path)) == nil,
          "el enlace ya no está")
    check(!sb.exists("_Retirados/\(hoy)/datos/real/dentro.txt"),
          "y no se ha retirado nada de la carpeta apuntada")
}

test("Nombres con acentos, espacios y emoji") {
    let sb = Sandbox("nombres")
    sb.write("Año nuevo/Cumpleaños de mamá.txt", "felicidades")
    sb.write("café ☕.md", "solo")

    let r = run(sb, sb.config())
    checkEq(r.errors.count, 0, "sin errores")
    check(sb.exists("datos/Año nuevo/Cumpleaños de mamá.txt"), "acentos y espacios")
    check(sb.exists("datos/café ☕.md"), "emoji")
}

test("Ensayo: cuenta lo que haría y no toca el disco") {
    let sb = Sandbox("ensayo")
    sb.write("a.txt", "1")
    sb.write("b.txt", "2")

    let r = run(sb, sb.config(), dryRun: true)
    checkEq(r.copied, 2, "dice que copiaría dos")
    check(!sb.exists("datos/a.txt"), "pero no ha copiado nada")
    check(!sb.exists("datos"), "ni ha creado la carpeta de destino")
}

test("Lo que aparece en el disco por su cuenta se retira") {
    let sb = Sandbox("intruso")
    sb.write("mio.txt", "1")
    _ = run(sb, sb.config())
    sb.write("datos/intruso.txt", "yo no vengo del Mac", in: sb.disco)

    let r = run(sb, sb.config())
    checkEq(r.retired, 1, "retira al intruso")
    check(sb.exists("_Retirados/\(hoy)/datos/intruso.txt"), "y va a la papelera como todo")
}

test("Retirar dos veces el mismo nombre el mismo día no pisa el primero") {
    let sb = Sandbox("colision")
    sb.write("vaiviene.txt", "primera versión")
    _ = run(sb, sb.config())
    try? fm.removeItem(at: sb.origen.appendingPathComponent("vaiviene.txt"))
    _ = run(sb, sb.config())

    sb.write("vaiviene.txt", "segunda versión")
    _ = run(sb, sb.config())
    try? fm.removeItem(at: sb.origen.appendingPathComponent("vaiviene.txt"))
    _ = run(sb, sb.config())

    checkEq(sb.read("_Retirados/\(hoy)/datos/vaiviene.txt"), "primera versión", "la primera sigue ahí")
    checkEq(sb.read("_Retirados/\(hoy)/datos/vaiviene-2.txt"), "segunda versión", "la segunda va al lado")
}

test("La papelera se purga sola pasado el plazo") {
    let sb = Sandbox("purga")
    sb.write("a.txt", "1")
    _ = run(sb, sb.config())

    // Una carpeta de retirados de hace 200 días, a mano.
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let vieja = df.string(from: Date().addingTimeInterval(-200 * 86400))
    sb.write("_Retirados/\(vieja)/datos/antiguo.txt", "de otra era", in: sb.disco)
    sb.write("_Retirados/\(hoy)/datos/reciente.txt", "de hoy", in: sb.disco)

    let r = run(sb, sb.config(retention: 90))
    checkEq(r.purged, 1, "purga una carpeta")
    check(!sb.exists("_Retirados/\(vieja)"), "la vieja se va")
    check(sb.exists("_Retirados/\(hoy)/datos/reciente.txt"), "la de hoy se queda")
}

test("A retención 0 no se purga nunca") {
    let sb = Sandbox("sinpurga")
    sb.write("a.txt", "1")
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let vieja = df.string(from: Date().addingTimeInterval(-3000 * 86400))
    sb.write("_Retirados/\(vieja)/datos/x.txt", "reliquia", in: sb.disco)

    let r = run(sb, sb.config(retention: 0))
    checkEq(r.purged, 0, "no purga")
    check(sb.exists("_Retirados/\(vieja)/datos/x.txt"), "la reliquia sigue ahí")
}

test("El destino dentro del origen se rechaza antes de tocar nada") {
    let sb = Sandbox("anidado")
    sb.write("a.txt", "1")
    var c = sb.config()
    // El disco, dentro de la carpeta que se está copiando: copia sin fin.
    c.folders = [SyncFolder(source: sb.root.path, name: "todo")]

    let motor = SyncEngine()
    var lanzo = false
    do { _ = try motor.run(config: c, root: sb.disco) } catch { lanzo = true }
    check(lanzo, "se niega a empezar")
}

test("Se puede cancelar a mitad") {
    let sb = Sandbox("cancelar")
    for i in 0..<200 { sb.write("f\(i).txt", String(repeating: "x", count: 500)) }

    let motor = SyncEngine()
    let cfg = sb.config()
    motor.onProgress = { done, _, _ in
        if done > 20 { motor.cancel() }
    }
    let r = (try? motor.run(config: cfg, root: sb.disco)) ?? SyncReport()
    check(r.cancelled, "el informe dice que se canceló")
    check(r.copied < 200, "no ha copiado los 200")
    check(r.copied > 0, "pero sí lo que le dio tiempo")
}

// Lo que hace falta para poder desconectar el disco sin esperar: parar en
// medio de un archivo grande, no al terminarlo. Con `copyItem` esto tardaría
// lo que tardase el archivo entero.
test("Detener a mitad de un archivo grande no espera a que acabe") {
    let sb = Sandbox("parar-grande")
    // 2 GB, creados como archivo «hueco»: se declara el tamaño y el sistema no
    // reserva nada hasta que se escriba. Así la prueba no tarda un minuto en
    // prepararse ni deja 2 GB ocupados, pero copiarlo sí cuesta lo suyo, que
    // es lo que hace falta para que dé tiempo a pedir que pare.
    let ruta = sb.origen.appendingPathComponent("pelicula.bin")
    fm.createFile(atPath: ruta.path, contents: nil)
    if let h = FileHandle(forWritingAtPath: ruta.path) {
        try? h.truncate(atOffset: 2 * 1024 * 1024 * 1024)
        try? h.close()
    }

    let motor = SyncEngine()
    let t0 = Date()
    // Se pide parar enseguida, con la copia ya empezada.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { motor.cancel() }
    let r = (try? motor.run(config: sb.config(), root: sb.disco)) ?? SyncReport()
    let tardó = Date().timeIntervalSince(t0)

    check(r.cancelled, "el informe dice que se canceló")
    check(tardó < 3, "y paró pronto, sin copiar los 2 GB — tardó \(String(format: "%.1f", tardó)) s")
    checkEq(r.errors.count, 0, "parar no cuenta como error")
    check(!sb.exists("datos/pelicula.bin"), "el archivo a medias no queda con el nombre bueno")
    let sobras = (try? fm.contentsOfDirectory(atPath: sb.disco.appendingPathComponent("datos").path)) ?? []
    check(!sobras.contains { $0.hasSuffix(".bssd-parcial") }, "ni queda el trozo temporal por ahí")
}

// Archivos en uso: alguien está escribiendo el archivo mientras lo copiamos.
// No se puede evitar, pero sí enterarse — y sobre todo, no dejar la copia a
// medias sellada como buena, porque entonces nunca se arreglaría sola.
test("Un archivo que cambia mientras se copia se marca y se rehace la próxima vez") {
    let sb = Sandbox("en-uso")
    let ruta = sb.origen.appendingPathComponent("diario.txt")
    // 2 GB: pasa de sobra el umbral de copia a trozos y tarda lo suficiente
    // como para que dé tiempo a tocarlo por debajo. Con 300 MB el disco lo
    // despachaba antes de que la prueba llegara a cambiar nada, y entonces no
    // se estaba probando lo que dice el título.
    fm.createFile(atPath: ruta.path, contents: nil)
    if let h = FileHandle(forWritingAtPath: ruta.path) {
        try? h.truncate(atOffset: 2 * 1024 * 1024 * 1024)
        try? h.close()
    }

    let motor = SyncEngine()
    // Mientras copia, otro programa guarda encima.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
        if let h = FileHandle(forWritingAtPath: ruta.path) {
            try? h.seek(toOffset: 0)
            h.write("el usuario acaba de guardar".data(using: .utf8)!)
            try? h.close()
        }
    }
    let r = (try? motor.run(config: sb.config(), root: sb.disco)) ?? SyncReport()

    check(!r.changed.isEmpty && r.changed.contains { $0.contains("diario.txt") },
          "queda anotado que cambió mientras se copiaba")

    // Lo que importa de verdad, pase lo que pase: la copia del disco no puede
    // quedar sellada con la fecha nueva, o se daría por buena para siempre.
    let dOrigen = (try? fm.attributesOfItem(atPath: ruta.path))?[.modificationDate] as? Date
    let dDisco = (try? fm.attributesOfItem(atPath: sb.disco.appendingPathComponent("datos/diario.txt").path))?[.modificationDate] as? Date
    if let o = dOrigen, let d = dDisco {
        check(abs(o.timeIntervalSince(d)) > SyncEngine.mtimeTolerance,
              "el original y la copia no coinciden en fecha, así que se recopiará")
    } else {
        check(false, "hacía falta poder leer las dos fechas")
    }

    // Y en la pasada siguiente, con el archivo ya quieto, se copia bien y
    // pasa a coincidir. (Se deja pequeño: lo que se prueba aquí es que se
    // vuelve a copiar, no lo rápido que va el disco.)
    try? "el usuario acaba de guardar".write(to: ruta, atomically: true, encoding: .utf8)
    let r2 = run(sb, sb.config())
    checkEq(r2.errors.count, 0, "la segunda pasada va limpia")
    let r3 = run(sb, sb.config())
    checkEq(r3.copied + r3.updated, 0, "y a la tercera ya no hay nada que hacer")
}

test("Un archivo que desaparece mientras se copia no cuenta como error") {
    let sb = Sandbox("desaparece")
    sb.write("queda.txt", "aquí sigo")
    let efimero = sb.origen.appendingPathComponent("temporal.txt")
    fm.createFile(atPath: efimero.path, contents: nil)
    if let h = FileHandle(forWritingAtPath: efimero.path) {
        try? h.truncate(atOffset: 300 * 1024 * 1024)
        try? h.close()
    }

    let motor = SyncEngine()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
        try? fm.removeItem(at: efimero)
    }
    let r = (try? motor.run(config: sb.config(), root: sb.disco)) ?? SyncReport()

    checkEq(r.errors.count, 0, "borrarse a mitad no es un fallo del backup")
    check(sb.exists("datos/queda.txt"), "y lo demás se copia igual")
}

test("Carpeta vacía en el Mac: también se crea en el disco") {
    let sb = Sandbox("vacia")
    sb.mkdir("carpeta vacía")
    sb.write("a.txt", "1")

    _ = run(sb, sb.config())
    var esDir: ObjCBool = false
    let existe = fm.fileExists(atPath: sb.disco.appendingPathComponent("datos/carpeta vacía").path,
                               isDirectory: &esDir)
    check(existe && esDir.boolValue, "la carpeta vacía llega como carpeta")
}

test("Dos carpetas con el mismo nombre de destino se avisan antes de correr") {
    let sb = Sandbox("duplicado")
    sb.mkdir("uno/docs"); sb.mkdir("dos/docs")
    var c = sb.config()
    c.folders = [
        SyncFolder(source: sb.origen.appendingPathComponent("uno/docs").path),
        SyncFolder(source: sb.origen.appendingPathComponent("dos/docs").path),
    ]
    let p = c.problems()
    check(p.contains { $0.contains("el mismo sitio") }, "el aviso sale por la configuración")
}

test("Una carpeta que ya no existe se avisa, no revienta") {
    let sb = Sandbox("desaparecida")
    var c = sb.config()
    c.folders = [SyncFolder(source: sb.origen.appendingPathComponent("fantasma").path)]
    check(c.problems().contains { $0.contains("ya no existe") }, "lo dice claro")
}

// MARK: - Mover

/// Si esa ruta del Mac existe y es una carpeta.
func esCarpetaEnElMac(_ sb: Sandbox, _ rel: String) -> Bool {
    var dir: ObjCBool = false
    let hay = fm.fileExists(atPath: sb.origen.appendingPathComponent(rel).path, isDirectory: &dir)
    return hay && dir.boolValue
}

func hayEnElMac(_ sb: Sandbox, _ rel: String) -> Bool {
    fm.fileExists(atPath: sb.origen.appendingPathComponent(rel).path)
}

/// Config con una sola carpeta, en modo mover, que se lleva todo el origen.
func configMover(_ sb: Sandbox) -> Config {
    var c = sb.config()
    c.folders = [SyncFolder(source: sb.origen.path, name: "datos", mode: .move)]
    return c
}

test("Mover: lo que hay en el Mac pasa al disco y se va del Mac") {
    let sb = Sandbox("mover-basico")
    sb.write("a.txt", "uno")
    sb.write("2024/b.txt", "dos")

    let r = run(sb, configMover(sb))
    checkEq(r.moved, 2, "cuenta los dos que ha movido")
    checkEq(r.retired, 0, "y no retira nada, que aquí no se retira nunca")
    check(sb.exists("datos/a.txt"), "el archivo llega al disco")
    checkEq(sb.read("datos/2024/b.txt"), "dos", "el de la subcarpeta, con su contenido")
    check(!hayEnElMac(sb, "a.txt"), "ya no está en el Mac")
    check(!hayEnElMac(sb, "2024/b.txt"), "ni el de dentro")
}

test("Mover: el esqueleto de carpetas se queda en el Mac, vacío") {
    let sb = Sandbox("mover-esqueleto")
    sb.write("2024/enero/a.txt", "x")

    _ = run(sb, configMover(sb))
    check(esCarpetaEnElMac(sb, "2024"), "la carpeta de fuera sigue ahí")
    check(esCarpetaEnElMac(sb, "2024/enero"), "y la de dentro también")
    checkEq((try? fm.contentsOfDirectory(atPath: sb.origen.appendingPathComponent("2024/enero").path))?.count, 0,
            "vacía, lista para volver a llenarse")
}

test("Mover: lo que ya estaba en el disco se queda donde está") {
    let sb = Sandbox("mover-acumula")
    sb.write("datos/archivado.txt", "de antes", in: sb.disco)
    sb.write("nuevo.txt", "de ahora")

    let r = run(sb, configMover(sb))
    checkEq(sb.read("datos/archivado.txt"), "de antes", "lo de antes sigue intacto")
    check(sb.exists("datos/nuevo.txt"), "y lo nuevo se le añade")
    checkEq(r.retired, 0, "no retira lo que no está en el Mac")
    check(!sb.exists("_Retirados"), "ni crea papelera ninguna")
}

test("Mover: un nombre repetido con otro contenido entra al lado, como «-2»") {
    let sb = Sandbox("mover-colision")
    sb.write("datos/informe.pdf", "el de marzo", in: sb.disco)
    sb.write("informe.pdf", "el de agosto")

    let r = run(sb, configMover(sb))
    checkEq(sb.read("datos/informe.pdf"), "el de marzo", "el que estaba no se toca")
    checkEq(sb.read("datos/informe-2.pdf"), "el de agosto", "y el que llega entra a su lado")
    checkEq(r.moved, 1, "cuenta uno movido")
    check(r.renamed.count == 1, "y avisa de que hubo que renombrarlo")
    check(!hayEnElMac(sb, "informe.pdf"), "el del Mac se va igualmente")
}

test("Mover: si en el disco ya está el mismo archivo, no se duplica") {
    let sb = Sandbox("mover-identico")
    sb.write("datos/nota.txt", "lo mismo", in: sb.disco)
    sb.write("nota.txt", "lo mismo")

    let r = run(sb, configMover(sb))
    check(!sb.exists("datos/nota-2.txt"), "no crea una copia de lo que ya estaba archivado")
    checkEq(sb.read("datos/nota.txt"), "lo mismo", "el del disco sigue igual")
    check(!hayEnElMac(sb, "nota.txt"), "y el del Mac se va, que para eso ya está guardado")
    checkEq(r.moved, 1, "cuenta como movido")
    checkEq(r.renamed.count, 0, "sin renombrar nada")
}

test("Mover: lo excluido no se copia, y sobre todo no se borra del Mac") {
    let sb = Sandbox("mover-excluido")
    sb.write("bueno.txt", "sí")
    sb.write(".DS_Store", "basura")
    sb.write("node_modules/lib.js", "no")

    _ = run(sb, configMover(sb))
    check(sb.exists("datos/bueno.txt"), "lo normal se mueve")
    check(!sb.exists("datos/.DS_Store"), "lo excluido no llega al disco")
    check(hayEnElMac(sb, ".DS_Store"), "y sigue en el Mac: lo que no se copia, no se borra")
    check(hayEnElMac(sb, "node_modules/lib.js"), "tampoco se vacía lo que ni se mira")
}

test("Mover: el ensayo cuenta lo que haría y no toca nada") {
    let sb = Sandbox("mover-ensayo")
    sb.write("a.txt", "uno")

    let r = run(sb, configMover(sb), dryRun: true)
    checkEq(r.moved, 1, "dice que movería uno")
    check(hayEnElMac(sb, "a.txt"), "pero el archivo sigue en el Mac")
    check(!sb.exists("datos/a.txt"), "y no ha llegado al disco")
}

test("Mover dentro de sincronizar: cada carpeta a lo suyo") {
    let sb = Sandbox("mover-anidada")
    sb.write("documentos/carta.txt", "hola")
    sb.write("documentos/otros/viejo.pdf", "de 2024")

    var c = sb.config()
    c.folders = [
        SyncFolder(source: sb.origen.appendingPathComponent("documentos").path, name: "Documentos"),
        SyncFolder(source: sb.origen.appendingPathComponent("documentos/otros").path,
                   name: "otros", mode: .move),
    ]
    checkEq(c.problems().count, 0, "la configuración no tiene nada que objetar")

    let r = run(sb, c)
    check(sb.exists("Documentos/carta.txt"), "lo sincronizado va a su sitio")
    check(sb.exists("Documentos/otros/viejo.pdf"), "y lo movido, a su sitio natural dentro")
    check(!hayEnElMac(sb, "documentos/otros/viejo.pdf"), "lo movido se fue del Mac")
    check(hayEnElMac(sb, "documentos/carta.txt"), "lo sincronizado sigue en el Mac")
    checkEq(r.retired, 0, "no se retira nada en la primera pasada")

    // La segunda pasada es la peligrosa: al recorrer el disco, «Documentos» ve
    // una carpeta «otros» llena de cosas que ya no están en el Mac. Si no se
    // la saltara, se las llevaría enteras a _Retirados.
    let r2 = run(sb, c)
    check(sb.exists("Documentos/otros/viejo.pdf"), "la segunda pasada no se lleva lo movido")
    checkEq(r2.retired, 0, "no retira nada")
    check(!sb.exists("_Retirados"), "ni crea papelera")
}

test("Mover: desactivar la carpeta no hace que la de fuera se lleve lo movido") {
    let sb = Sandbox("mover-desactivada")
    sb.write("documentos/otros/viejo.pdf", "de 2024")

    var c = sb.config()
    c.folders = [
        SyncFolder(source: sb.origen.appendingPathComponent("documentos").path, name: "Documentos"),
        SyncFolder(source: sb.origen.appendingPathComponent("documentos/otros").path,
                   name: "otros", mode: .move),
    ]
    _ = run(sb, c)
    check(sb.exists("Documentos/otros/viejo.pdf"), "primero se mueve")

    // Desactivar quiere decir «no la toques», nunca «trágatela desde fuera».
    c.folders[1].enabled = false
    let r = run(sb, c)
    check(sb.exists("Documentos/otros/viejo.pdf"), "y desactivada sigue sin tocarse")
    checkEq(r.retired, 0, "no se retira nada")
}

test("El destino de una carpeta anidada sale de la de fuera") {
    let sb = Sandbox("destinos")
    sb.mkdir("documentos/otros/hondo")

    var c = sb.config()
    let docs = SyncFolder(source: sb.origen.appendingPathComponent("documentos").path, name: "Documentos")
    let otros = SyncFolder(source: sb.origen.appendingPathComponent("documentos/otros").path,
                           name: "otros", mode: .move)
    let hondo = SyncFolder(source: sb.origen.appendingPathComponent("documentos/otros/hondo").path,
                           name: "hondo")
    c.folders = [docs, otros, hondo]

    let d = URL(fileURLWithPath: "/D")
    checkEq(c.destination(of: docs, under: d).path, "/D/Documentos", "la de fuera, a su nombre")
    checkEq(c.destination(of: otros, under: d).path, "/D/Documentos/otros", "la de dentro, a su sitio natural")
    checkEq(c.destination(of: hondo, under: d).path, "/D/Documentos/otros/hondo", "y la de más adentro, también")
    checkEq(c.nestedRelativePaths(of: docs), ["otros"], "«Documentos» se salta «otros» y sólo eso")
    checkEq(c.nestedRelativePaths(of: otros), ["hondo"], "y «otros» se salta «hondo»")
    checkEq(c.nestedRelativePaths(of: hondo), [], "la de más adentro no se salta nada")
}

test("Dos destinos anidados sin estarlo en el Mac se avisan") {
    let sb = Sandbox("destinos-cruzados")
    sb.mkdir("uno"); sb.mkdir("dos")

    var c = sb.config()
    // Un `name` con barras es lo que alguien podría escribir a mano en el
    // config.json, y dejaría a «dos» recorriendo el destino de «uno».
    var raro = SyncFolder(source: sb.origen.appendingPathComponent("uno").path, name: "uno")
    raro.name = "dos/uno"
    c.folders = [raro, SyncFolder(source: sb.origen.appendingPathComponent("dos").path, name: "dos")]

    let p = c.problems()
    check(p.contains { $0.contains("no vale como nombre") } || p.contains { $0.contains("cae dentro") },
          "la configuración se queja")
}

// MARK: - Discos
//
// No se puede enchufar un SSD desde una prueba, pero sí comprobar lo que
// decide qué disco es el bueno, que es la parte peligrosa. Se ejercita contra
// los volúmenes que haya montados de verdad en esta máquina.

test("Los volúmenes montados se leen con su UUID") {
    let montados = Volumes.mounted()
    check(!montados.isEmpty, "encuentra al menos un volumen")
    check(montados.allSatisfy { !$0.uuid.isEmpty }, "todos traen UUID")
    check(montados.allSatisfy { !$0.name.isEmpty }, "todos traen nombre")

    // El disco de arranque tiene que estar, y verse como interno.
    let arranque = Volumes.info(of: URL(fileURLWithPath: "/"))
    check(arranque != nil, "el disco de arranque se lee")
    if let a = arranque {
        check(montados.contains { $0.uuid == a.uuid }, "y sale en la lista")
    }
}

test("Buscar por UUID: encuentra el que es y sólo ese") {
    guard let arranque = Volumes.info(of: URL(fileURLWithPath: "/")) else {
        check(false, "hacía falta el disco de arranque"); return
    }
    checkEq(Volumes.find(uuid: arranque.uuid)?.uuid, arranque.uuid, "encuentra el disco por su UUID")
    check(Volumes.find(uuid: "00000000-0000-0000-0000-000000000000") == nil,
          "un UUID que no existe no devuelve nada")
    check(Volumes.find(uuid: "") == nil, "y un UUID vacío tampoco")
}

// Lo importante de verdad: sin disco reconocido no se devuelve ninguna ruta.
// Si esto fallara y devolviera algo, el motor escribiría —y retiraría— en un
// sitio que no es el disco de backup.
test("Sin el disco puesto no hay ruta de destino que valga") {
    var c = Config()
    c.volumeUUID = ""
    var lanzo = false
    do { _ = try Volumes.backupRoot(config: c) } catch { lanzo = true }
    check(lanzo, "con la configuración vacía se niega")

    c.volumeUUID = "00000000-0000-0000-0000-000000000000"
    c.volumeName = "SSD que no está"
    lanzo = false
    do { _ = try Volumes.backupRoot(config: c) } catch { lanzo = true }
    check(lanzo, "con un disco que no está montado, también")
}

test("La raíz del backup cuelga del disco y de su carpeta") {
    guard let arranque = Volumes.info(of: URL(fileURLWithPath: "/")) else {
        check(false, "hacía falta el disco de arranque"); return
    }
    var c = Config()
    c.volumeUUID = arranque.uuid
    c.rootFolder = "Mi-Backup"
    let ruta = try? Volumes.backupRoot(config: c)
    checkEq(ruta?.lastPathComponent, "Mi-Backup", "usa la carpeta configurada")
    check(ruta?.path.hasPrefix(arranque.url.path) ?? false, "y cuelga del disco elegido")

    // Una carpeta raíz en blanco dejaría el backup en la raíz del disco, donde
    // «retirar lo que no está en el Mac» se llevaría por delante todo lo demás.
    c.rootFolder = "   "
    checkEq((try? Volumes.backupRoot(config: c))?.lastPathComponent, "Backup-SSD",
            "una carpeta en blanco cae al valor de siempre, no a la raíz del disco")
}

// MARK: - Resultado

print("\n" + String(repeating: "─", count: 60))
if fallos.isEmpty {
    print("✅ \(pasadas) comprobaciones, todas en verde")
    exit(0)
} else {
    print("❌ \(fallos.count) fallos de \(pasadas + fallos.count):")
    for f in fallos { print("   · \(f)") }
    exit(1)
}
