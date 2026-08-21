// El motor: compara el Mac con el disco y deja el disco igual que el Mac.
//
// No depende de SwiftUI ni de AppKit a propósito. Así se puede compilar y
// probar desde la terminal (ver macapp/tests), que es la única forma sensata
// de tener confianza en un programa que borra archivos.
//
// Cómo funciona, en una frase: se hace una lista de lo que hay a cada lado, se
// compara, se decide qué hacer con cada archivo, y sólo entonces se toca el
// disco. Planificar primero permite saber cuánto espacio hace falta antes de
// escribir el primer byte, y da un progreso que significa algo.

import Foundation

// MARK: - Qué se ha hecho

struct SyncReport {
    var copied = 0            // archivos nuevos en el disco
    var updated = 0           // ya estaban, pero habían cambiado
    var retired = 0           // ya no están en el Mac
    var unchanged = 0
    /// Se llevaron al disco y se borraron del Mac (carpetas en modo mover).
    var moved = 0
    /// Se copiaron, pero el original **sigue en el Mac** porque lo que llegó
    /// al disco no coincidía con lo que salió. Nunca es un borrado a ciegas:
    /// si la comprobación falla, el archivo se queda donde estaba.
    var unverified: [String] = []
    /// Ya había uno con ese nombre en el disco, con otro contenido, y el que
    /// llegaba entró al lado como «-2».
    var renamed: [String] = []
    var skipped: [String] = []   // iCloud sin descargar, y demás
    var errors: [String] = []
    /// Estaban siendo modificados mientras se copiaban. La copia que ha
    /// quedado en el disco puede ser un a medias, así que se marca para que la
    /// próxima pasada la haga otra vez.
    var changed: [String] = []
    /// Se borraron entre el momento de mirar y el de copiar. No es un fallo.
    var vanished: [String] = []
    var bytesWritten: Int64 = 0
    var purged = 0            // carpetas de _Retirados borradas por antigüedad
    var duration: TimeInterval = 0
    var cancelled = false

    var touched: Int { copied + updated + retired + moved }

    /// Resumen de una línea para el registro y para la barra de menús.
    var summary: String {
        if cancelled { return L("Detenido — %@ copiados antes de parar", plural("%ld archivos", copied + updated + moved)) }
        var partes: [String] = []
        if copied > 0  { partes.append(plural("%ld nuevos", copied)) }
        if updated > 0 { partes.append(plural("%ld actualizados", updated)) }
        if moved > 0   { partes.append(plural("%ld movidos", moved)) }
        if retired > 0 { partes.append(plural("%ld retirados", retired)) }
        if partes.isEmpty { partes.append(L("sin cambios")) }
        if !errors.isEmpty { partes.append(plural("%ld con error", errors.count)) }
        return partes.joined(separator: ", ")
    }
}

enum SyncError: LocalizedError {
    case noDestination(String)
    case wrongVolume(expected: String, found: String)
    case notEnoughSpace(needed: Int64, free: Int64)
    case disconnected
    case nested(String)
    /// Se ha pedido parar a mitad de un archivo. No es un fallo, y por eso no
    /// se apunta en la lista de errores del informe.
    case stopped

    var errorDescription: String? {
        switch self {
        case .noDestination(let p):
            return L("El disco no está montado o la carpeta %@ no existe.", p)
        case .wrongVolume(let e, let f):
            return L("Ese no es el disco de siempre: se esperaba %1$@ y hay %2$@. No se ha tocado nada.", e, f)
        case .notEnoughSpace(let n, let f):
            return L("No cabe: hacen falta %1$@ y quedan %2$@ libres.", fmtBytes(n), fmtBytes(f))
        case .disconnected:
            return L("El disco se ha desconectado a mitad de la copia.")
        case .nested(let m):
            return m
        case .stopped:
            return L("Detenido a mitad de un archivo.")
        }
    }
}

// MARK: - Un archivo, a cada lado

private struct Entry {
    let rel: String
    let isDir: Bool
    let isSymlink: Bool
    let size: Int64
    let mtime: Date
    /// A dónde apunta, si es un enlace simbólico. Se guarda para no recrear en
    /// cada pasada enlaces que no han cambiado.
    var linkTarget: String? = nil
}

// MARK: - Lo que hay que hacer

private enum Action {
    case copy(rel: String, size: Int64, mtime: Date, isNew: Bool)
    case makeDir(rel: String)
    case link(rel: String)              // enlace simbólico: se recrea, no se sigue
    case retire(rel: String, isDir: Bool)
    /// Llevar al disco y borrar del Mac. Sólo en carpetas en modo mover, y
    /// sólo después de comprobar que lo que llegó al disco es lo que salió.
    case move(rel: String, size: Int64, mtime: Date, isSymlink: Bool)
}

// MARK: - Las cuentas de un movimiento

/// Lo que los hilos que mueven archivos se van diciendo entre ellos.
///
/// Va en una clase con su propio cerrojo, y no en variables sueltas capturadas
/// por el closure como en las copias, porque aquí no sólo se suman cosas: se
/// **reparten nombres de archivo**. Dos hilos que eligieran el mismo «-2» a la
/// vez harían que el segundo escribiera encima del primero, y del primero ya
/// no queda copia en el Mac. Con el cerrojo pegado a los datos no hay forma de
/// tocar unos sin el otro.
private final class MoveTally: @unchecked Sendable {
    private let lock = NSLock()

    private(set) var hechos = 0
    private(set) var errores: [String] = []
    private(set) var desaparecidos: [String] = []
    private(set) var sinVerificar: [String] = []
    private(set) var renombrados: [String] = []
    private(set) var movidos = 0
    private(set) var bytes: Int64 = 0
    private(set) var desconectado = false

    /// Nombres del disco que algún hilo ya ha pedido para sí, estén escritos
    /// todavía o no.
    private var ocupados: Set<String> = []

    init(hechos: Int) { self.hechos = hechos }

    func get<T>(_ campo: KeyPath<MoveTally, T>) -> T {
        lock.lock(); defer { lock.unlock() }
        return self[keyPath: campo]
    }

    func marcarDesconectado() {
        lock.lock(); desconectado = true; lock.unlock()
    }

    // MARK: Repartir nombres

    /// Con qué nombre entra este archivo, y si donde iba había ya algo.
    ///
    /// El `existe` mira el disco desde dentro del cerrojo. Es una llamada a
    /// stat, y tiene que ser ahí: comprobar fuera y reservar después deja una
    /// rendija por la que dos hilos ven libre el mismo nombre.
    func reservar(_ preferido: URL, existe: (URL) -> Bool) -> (url: URL, ocupado: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !ocupados.contains(preferido.path) {
            ocupados.insert(preferido.path)
            return (preferido, existe(preferido))
        }
        return (buscarLibre(preferido, existe: existe), false)
    }

    /// Otro nombre, para cuando el preferido lo ocupa un archivo que no es el
    /// mismo que se está moviendo.
    func reservarLibre(_ preferido: URL, existe: (URL) -> Bool) -> URL {
        lock.lock(); defer { lock.unlock() }
        return buscarLibre(preferido, existe: existe)
    }

    /// Con el cerrojo ya cogido.
    private func buscarLibre(_ preferido: URL, existe: (URL) -> Bool) -> URL {
        let dir = preferido.deletingLastPathComponent()
        let ext = preferido.pathExtension
        let base = preferido.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let nombre = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            let candidato = dir.appendingPathComponent(nombre)
            if !ocupados.contains(candidato.path), !existe(candidato) {
                ocupados.insert(candidato.path)
                return candidato
            }
            n += 1
        }
    }

    // MARK: Apuntar

    /// Uno menos que hacer, y nada que contar: se paró a mitad.
    func apuntar() {
        lock.lock(); hechos += 1; lock.unlock()
    }

    func apuntar(error: String) {
        lock.lock(); hechos += 1; errores.append(error); lock.unlock()
    }

    func apuntar(desaparecido: String) {
        lock.lock(); hechos += 1; desaparecidos.append(desaparecido); lock.unlock()
    }

    func apuntar(sinVerificar cual: String) {
        lock.lock(); hechos += 1; sinVerificar.append(cual); lock.unlock()
    }

    func apuntar(movido escritos: Int64, renombradoA: String?, etiqueta: String) {
        lock.lock(); defer { lock.unlock() }
        hechos += 1
        movidos += 1
        bytes += escritos
        if let r = renombradoA { renombrados.append(L("%1$@ → %2$@", etiqueta, r)) }
    }
}

// MARK: - Motor

/// `@unchecked Sendable` porque el motor cruza de hilo a propósito: corre en
/// una cola de fondo mientras la interfaz, desde la principal, puede llamar a
/// `cancel()`. Lo único que se toca desde los dos lados es la bandera de
/// cancelación, y esa va bajo `NSLock`. Los dos closures se asignan antes de
/// arrancar y no se vuelven a tocar.
final class SyncEngine: @unchecked Sendable {
    /// Marcas de tiempo: se consideran iguales si no se separan más de dos
    /// segundos. No es dejadez, es exFAT: guarda la fecha con resolución de
    /// dos segundos, así que un archivo recién copiado ya vuelve «distinto» al
    /// compararlo con el original en APFS. Sin esta tolerancia, cada
    /// sincronización recopiaría el disco entero.
    static let mtimeTolerance: TimeInterval = 2

    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
    func reset() {
        lock.lock(); _cancelled = false; lock.unlock()
    }

    private let fm = FileManager.default

    /// Se avisa del progreso desde la cola en la que corre el motor, no desde
    /// la principal: quien lo reciba se encarga de saltar a la suya.
    var onProgress: ((_ done: Int, _ total: Int, _ current: String) -> Void)?
    var onLog: ((String) -> Void)?

    // MARK: Ejecución

    /// - Parameters:
    ///   - root: carpeta raíz dentro del disco (ya montada).
    ///   - dryRun: planifica y cuenta, pero no escribe nada.
    func run(config cfg: Config, root: URL, dryRun: Bool = false) throws -> SyncReport {
        let started = Date()
        var report = SyncReport()

        guard fm.fileExists(atPath: root.path) || !dryRun else {
            throw SyncError.noDestination(root.path)
        }
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let folders = cfg.folders.filter(\.enabled)
        let matcher = ExcludeMatcher(patterns: cfg.excludes)

        // --- 1. Planificar todo antes de tocar nada -------------------------
        var planes: [(SyncFolder, [Action])] = []
        var bytesNeeded: Int64 = 0
        var totalActions = 0

        for folder in folders {
            if isCancelled { report.cancelled = true; return report }
            let dest = cfg.destination(of: folder, under: root)
            try assertNotNested(source: folder.source, destination: dest)

            onProgress?(0, 0, L("Comparando «%@»…", folder.name))
            let origen = URL(fileURLWithPath: folder.source)
            // Preguntar por iCloud es carísimo (ver `scan`), así que se decide
            // una sola vez por carpeta en lugar de una vez por archivo.
            let mirarNube = cfg.skipUndownloadediCloud && isInICloud(origen)
            // Las carpetas configuradas que cuelgan de esta se saltan a los dos
            // lados: cada una es dueña de su subárbol y se trata con sus
            // propias reglas. Ver `Config.nestedRelativePaths(of:)`.
            let saltar = cfg.nestedRelativePaths(of: folder)

            let actions: [Action]
            if folder.mode == .move {
                // Aquí no se mira el disco. En modo mover se lleva todo lo que
                // haya en el Mac y lo que ya esté en el disco se queda como
                // está: no hay nada que comparar y nada que retirar. Las
                // coincidencias de nombre se resuelven al escribir, que es
                // cuando se sabe de verdad lo que hay al otro lado.
                let src = scan(origen, matcher: matcher, cloudKeys: mirarNube, skip: saltar)
                report.errors += src.errors
                report.skipped += src.skipped
                actions = makeMovePlan(source: src.entries)
            } else {
                let hayDestino = fm.fileExists(atPath: dest.path)

                // Los dos lados a la vez: el Mac y el disco externo son dos
                // aparatos distintos, y mientras uno contesta el otro está
                // parado. Es la mitad del tiempo de la pasada en la que no
                // cambia nada, que es la que se hace casi siempre.
                var lados: [Int: ScanResult] = [:]
                let cerrojo = NSLock()
                DispatchQueue.concurrentPerform(iterations: hayDestino ? 2 : 1) { i in
                    let r = i == 0
                        ? self.scan(origen, matcher: matcher, cloudKeys: mirarNube, skip: saltar)
                        : self.scan(dest, matcher: matcher, cloudKeys: false, skip: saltar)
                    cerrojo.lock(); lados[i] = r; cerrojo.unlock()
                }
                let src = lados[0] ?? ScanResult()
                let dst = lados[1] ?? ScanResult()
                report.errors += src.errors + dst.errors
                report.skipped += src.skipped

                actions = makePlan(source: src.entries, destination: dst.entries, report: &report)
            }

            for a in actions {
                switch a {
                case .copy(_, let size, _, _), .move(_, let size, _, _): bytesNeeded += size
                case .makeDir, .link, .retire: break
                }
            }
            totalActions += actions.count
            planes.append((folder, actions))
        }

        // --- 2. ¿Cabe? ------------------------------------------------------
        // Se comprueba con el total, aunque parte de lo que se copia sustituya
        // a algo que ya está: quedarse sin espacio a mitad es peor que no
        // empezar, y afinar el cálculo pediría saber el tamaño de cada archivo
        // que se reemplaza. Se pide un 5 % de margen.
        if !dryRun, bytesNeeded > 0 {
            if let free = freeSpace(at: root) {
                let needed = bytesNeeded + bytesNeeded / 20
                if needed > free { throw SyncError.notEnoughSpace(needed: needed, free: free) }
            }
        }

        if dryRun {
            for (_, actions) in planes {
                for a in actions {
                    switch a {
                    case .copy(_, _, _, let isNew): if isNew { report.copied += 1 } else { report.updated += 1 }
                    case .move: report.moved += 1
                    case .retire: report.retired += 1
                    case .makeDir, .link: break
                    }
                }
            }
            report.duration = Date().timeIntervalSince(started)
            return report
        }

        // --- 3. Ejecutar ----------------------------------------------------
        let retiradosDir = root.appendingPathComponent("_Retirados/\(Self.today())", isDirectory: true)
        var done = 0

        for (folder, actions) in planes {
            let dest = cfg.destination(of: folder, under: root)
            let origen = URL(fileURLWithPath: folder.source)

            // El plan viene en bloques y cada uno se ejecuta a su manera.
            // Las carpetas, en orden y de una en una: el padre antes que el
            // hijo. Las copias y los movimientos, varios a la vez. Las
            // retiradas, otra vez de una en una y de dentro hacia fuera,
            // porque mover una carpeta mientras otro hilo mueve algo de
            // dentro es pedir un lío.
            var carpetas: [Action] = [], copias: [Action] = [], retiradas: [Action] = []
            var movimientos: [Action] = []
            for a in actions {
                switch a {
                case .makeDir:        carpetas.append(a)
                case .copy, .link:    copias.append(a)
                case .move:           movimientos.append(a)
                case .retire:         retiradas.append(a)
                }
            }

            for case .makeDir(let rel) in carpetas {
                if isCancelled { break }
                let url = dest.appendingPathComponent(rel)
                do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
                catch { report.errors.append(L("No se pudo crear %1$@: %2$@", rel, error.localizedDescription)) }
            }
            done += carpetas.count

            if !isCancelled {
                try copiarEnParalelo(copias, from: origen, to: dest, folderName: folder.name,
                                     root: root, done: &done, total: totalActions, report: &report)
            }

            if !isCancelled {
                try moverEnParalelo(movimientos, from: origen, to: dest, folderName: folder.name,
                                    root: root, done: &done, total: totalActions, report: &report)
            }

            for case .retire(let rel, let isDir) in retiradas {
                if isCancelled { break }
                done += 1
                if done % 50 == 0, !fm.fileExists(atPath: root.path) {
                    throw SyncError.disconnected
                }
                let victim = dest.appendingPathComponent(rel)
                onProgress?(done, totalActions, rel)
                do {
                    if cfg.keepRemoved {
                        let to = retiradosDir.appendingPathComponent(folder.name).appendingPathComponent(rel)
                        try retire(victim, to: to)
                    } else {
                        try fm.removeItem(at: victim)
                    }
                    report.retired += 1
                } catch {
                    // Una carpeta que no se puede retirar porque ya no está
                    // —se fue con su padre— no es un error.
                    if fm.fileExists(atPath: victim.path) {
                        report.errors.append(L("Al retirar %1$@: %2$@",
                                               "\(folder.name)/\(rel)", error.localizedDescription))
                    } else if isDir {
                        report.retired += 1
                    }
                }
            }

            if isCancelled { report.cancelled = true; break }
        }

        // --- 4. Purga de lo retirado hace mucho -----------------------------
        if cfg.keepRemoved, cfg.removedRetentionDays > 0, !report.cancelled {
            report.purged = purgeOldRetired(root: root, days: cfg.removedRetentionDays, report: &report)
        }

        report.duration = Date().timeIntervalSince(started)
        return report
    }

    /// Cuántos archivos se copian a la vez.
    ///
    /// Copiar un archivo es sobre todo esperar: abrir, leer, escribir, cerrar,
    /// renombrar. Mientras un hilo espera al disco, otro puede ir preparando
    /// lo suyo, y con archivos pequeños —que son la mayoría— se gana mucho.
    /// Cuatro y no dieciséis: pasado cierto punto sólo se consigue que el
    /// disco vaya y venga entre sitios distintos, y en uno externo por USB eso
    /// se paga caro.
    static let concurrentCopies = 4

    /// Ejecuta las copias y los enlaces repartidos entre varios hilos.
    ///
    /// El reparto es por demanda —cada hilo coge el siguiente que quede— y no
    /// en trozos iguales: un trozo con los cuatro archivos de vídeo tardaría
    /// más que los otros tres juntos y los dejaría esperando.
    private func copiarEnParalelo(_ acciones: [Action], from origen: URL, to dest: URL,
                                  folderName: String, root: URL,
                                  done: inout Int, total: Int,
                                  report: inout SyncReport) throws {
        guard !acciones.isEmpty else { return }

        let cerrojo = NSLock()
        var siguiente = 0
        var hechos = done
        var errores: [String] = []
        var desaparecidos: [String] = []
        var cambiados: [String] = []
        var copiados = 0, actualizados = 0
        var bytes: Int64 = 0
        var desconectado = false

        let hilos = min(Self.concurrentCopies, acciones.count)
        DispatchQueue.concurrentPerform(iterations: hilos) { _ in
            while true {
                cerrojo.lock()
                let i = siguiente
                siguiente += 1
                cerrojo.unlock()
                guard i < acciones.count, !self.isCancelled, !desconectado else { return }

                var falloAlCopiar: String? = nil
                var bytesDeEste: Int64 = 0
                var esNuevo: Bool? = nil
                var seFue: String? = nil
                var cambióAlVuelo: String? = nil
                var rel = ""

                switch acciones[i] {
                case .copy(let r, let size, let mtime, let isNew):
                    rel = r
                    let fuente = origen.appendingPathComponent(r)
                    do {
                        let cambió = try self.copyAtomically(
                            from: fuente, to: dest.appendingPathComponent(r),
                            size: size, mtime: mtime)
                        bytesDeEste = size
                        esNuevo = isNew
                        // Si alguien lo estaba escribiendo, la copia ya ha
                        // quedado marcada para rehacerse; aquí sólo se apunta
                        // para poder decirlo en el informe.
                        if cambió { cambióAlVuelo = "\(folderName)/\(r)" }
                    } catch {
                        // Haber parado a mitad no es un fallo del que informar:
                        // es lo que se acaba de pedir.
                        if self.isCancelled {
                            // nada que decir
                        } else if !self.fm.fileExists(atPath: fuente.path) {
                            // Se ha borrado entre mirar y copiar. Pasa con los
                            // temporales de cualquier programa que esté
                            // trabajando, y no es un fallo del backup.
                            seFue = "\(folderName)/\(r)"
                        } else {
                            falloAlCopiar = "\(folderName)/\(r): \(error.localizedDescription)"
                        }
                    }
                case .link(let r):
                    rel = r
                    do {
                        try self.copySymlink(from: origen.appendingPathComponent(r),
                                             to: dest.appendingPathComponent(r))
                    } catch {
                        falloAlCopiar = L("Enlace %1$@: %2$@", r, error.localizedDescription)
                    }
                case .makeDir, .retire, .move:
                    continue      // no llegan aquí
                }

                cerrojo.lock()
                hechos += 1
                if let e = falloAlCopiar { errores.append(e) }
                if let v = seFue { desaparecidos.append(v) }
                if let c = cambióAlVuelo { cambiados.append(c) }
                bytes += bytesDeEste
                if let nuevo = esNuevo { if nuevo { copiados += 1 } else { actualizados += 1 } }
                let cuenta = hechos
                cerrojo.unlock()

                // El disco puede irse en cualquier momento. Mirarlo cada 50
                // evita cientos de errores idénticos, y sobre todo evita
                // seguir escribiendo contra una carpeta que ya no está.
                if cuenta % 50 == 0, !self.fm.fileExists(atPath: root.path) {
                    cerrojo.lock(); desconectado = true; cerrojo.unlock()
                    return
                }
                self.onProgress?(cuenta, total, rel)
            }
        }

        done = hechos
        report.errors += errores
        report.vanished += desaparecidos
        report.changed += cambiados
        report.bytesWritten += bytes
        report.copied += copiados
        report.updated += actualizados
        if desconectado { throw SyncError.disconnected }
    }

    /// Lleva al disco lo que hay en el Mac y lo borra de allí, repartido entre
    /// varios hilos como las copias.
    ///
    /// Es la única parte del programa que borra algo del Mac, así que el orden
    /// no se negocia: se copia, se relee del disco y se compara con el
    /// original, y **sólo entonces** se borra. Si la comprobación no sale
    /// bien, se retira lo que se había escrito, el archivo se queda donde
    /// estaba y se dice en el informe. Es preferible repetir el movimiento
    /// mañana a descubrir dentro de un año que lo archivado era medio archivo.
    ///
    /// Las carpetas no se borran nunca: el esqueleto se queda en el Mac,
    /// vacío, listo para volver a llenarse.
    private func moverEnParalelo(_ acciones: [Action], from origen: URL, to dest: URL,
                                 folderName: String, root: URL,
                                 done: inout Int, total: Int,
                                 report: inout SyncReport) throws {
        guard !acciones.isEmpty else { return }

        let cuentas = MoveTally(hechos: done)
        var siguiente = 0
        let reparto = NSLock()

        let hilos = min(Self.concurrentCopies, acciones.count)
        DispatchQueue.concurrentPerform(iterations: hilos) { _ in
            while true {
                reparto.lock()
                let i = siguiente
                siguiente += 1
                reparto.unlock()
                guard i < acciones.count, !self.isCancelled, !cuentas.get(\.desconectado) else { return }
                guard case .move(let rel, let size, let mtime, let esEnlace) = acciones[i] else { continue }

                let fuente = origen.appendingPathComponent(rel)
                let etiqueta = "\(folderName)/\(rel)"
                self.moverUno(fuente, to: dest.appendingPathComponent(rel),
                              size: size, mtime: mtime, isSymlink: esEnlace,
                              etiqueta: etiqueta, cuentas: cuentas)

                let cuenta = cuentas.get(\.hechos)
                // El disco puede irse en cualquier momento. Mirarlo cada 50
                // evita cientos de errores idénticos y, sobre todo, evita
                // seguir borrando del Mac archivos cuyo destino ya no está.
                if cuenta % 50 == 0, !self.fm.fileExists(atPath: root.path) {
                    cuentas.marcarDesconectado()
                    return
                }
                self.onProgress?(cuenta, total, etiqueta)
            }
        }

        done = cuentas.get(\.hechos)
        report.errors += cuentas.get(\.errores)
        report.vanished += cuentas.get(\.desaparecidos)
        report.unverified += cuentas.get(\.sinVerificar)
        report.renamed += cuentas.get(\.renombrados)
        report.bytesWritten += cuentas.get(\.bytes)
        report.moved += cuentas.get(\.movidos)
        if cuentas.get(\.desconectado) { throw SyncError.disconnected }
    }

    /// Un archivo del Mac al disco: copiar, comprobar, borrar. En ese orden.
    private func moverUno(_ fuente: URL, to preferido: URL, size: Int64, mtime: Date,
                          isSymlink esEnlace: Bool, etiqueta: String, cuentas: MoveTally) {
        // --- 1. ¿Con qué nombre entra? ----------------------------------
        // `attributesOfItem` y no `fileExists`, que sigue los enlaces: uno
        // roto existe y no lo parece, y escribir encima de él se llevaría por
        // delante algo que ya se había archivado.
        let (destinoInicial, ocupado) = cuentas.reservar(preferido) {
            (try? self.fm.attributesOfItem(atPath: $0.path)) != nil
        }
        var destino = destinoInicial
        var renombradoA: String? = destino == preferido ? nil : destino.lastPathComponent

        // --- 2. Si ya había algo ahí, ¿es lo mismo? ---------------------
        if ocupado {
            if esElMismo(fuente, destino, size: size, isSymlink: esEnlace) {
                // Ya estaba archivado y es idéntico. Duplicarlo como «-2» sólo
                // llenaría el disco de copias de lo mismo cada vez que el
                // archivo reapareciera en el Mac. Basta con quitarlo de aquí.
                do {
                    try fm.removeItem(at: fuente)
                    cuentas.apuntar(movido: 0, renombradoA: nil, etiqueta: etiqueta)
                } catch {
                    if !fm.fileExists(atPath: fuente.path) { cuentas.apuntar(desaparecido: etiqueta) }
                    else { cuentas.apuntar(error: "\(etiqueta): \(error.localizedDescription)") }
                }
                return
            }
            // Es otro archivo con el mismo nombre. El de antes no se toca —ya
            // no está en el Mac y no hay otra copia en ninguna parte— y el que
            // llega entra a su lado.
            destino = cuentas.reservarLibre(preferido) {
                (try? self.fm.attributesOfItem(atPath: $0.path)) != nil
            }
            renombradoA = destino.lastPathComponent
        }

        // --- 3. Copiar, comprobar, y sólo entonces borrar ---------------
        do {
            var escritos: Int64 = 0
            if esEnlace {
                try copySymlink(from: fuente, to: destino)
            } else {
                try copyAtomically(from: fuente, to: destino, size: size, mtime: mtime)
                escritos = size
            }

            if esElMismo(fuente, destino, size: size, isSymlink: esEnlace) {
                // La fecha buena, por si `copyAtomically` marcó el archivo como
                // sospechoso: allí la sospecha se apunta en la fecha porque no
                // hay nada mejor, pero aquí acabamos de comparar el contenido
                // entero y sabemos que está bien.
                if !esEnlace { try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: destino.path) }
                try fm.removeItem(at: fuente)
                cuentas.apuntar(movido: escritos, renombradoA: renombradoA, etiqueta: etiqueta)
            } else if isCancelled {
                // La comparación se corta al cancelar y devuelve que no
                // cuadran, que es lo prudente pero no es verdad. Se deshace lo
                // escrito igual, y no se apunta como sospechoso: no lo es, sólo
                // se ha pedido parar.
                try? fm.removeItem(at: destino)
                cuentas.apuntar()
            } else {
                // Lo que llegó no es lo que salió: alguien estaba guardando el
                // archivo, o el disco escribió mal. Se deshace lo escrito para
                // no dejar medio archivo con nombre de bueno, y el original se
                // queda en el Mac para volver a intentarlo mañana.
                try? fm.removeItem(at: destino)
                cuentas.apuntar(sinVerificar: etiqueta)
            }
        } catch {
            if isCancelled {
                cuentas.apuntar()      // parar a mitad no es un fallo
            } else if !fm.fileExists(atPath: fuente.path) {
                cuentas.apuntar(desaparecido: etiqueta)
            } else {
                cuentas.apuntar(error: "\(etiqueta): \(error.localizedDescription)")
            }
        }
    }

    /// Si el archivo del disco es el mismo que el del Mac, byte a byte.
    ///
    /// Comparar el contenido y no la fecha y el tamaño, que es lo que hace el
    /// modo sincronizar, porque lo que viene después es borrar el original: si
    /// la comprobación se equivoca, no hay segunda copia en ninguna parte. Se
    /// paga una relectura de lo que se mueve —no del backup entero—, y sólo la
    /// primera vez que cada archivo pasa por aquí.
    private func esElMismo(_ mac: URL, _ disco: URL, size: Int64, isSymlink: Bool) -> Bool {
        if isSymlink {
            guard let a = try? fm.destinationOfSymbolicLink(atPath: mac.path),
                  let b = try? fm.destinationOfSymbolicLink(atPath: disco.path) else { return false }
            return a == b
        }
        guard let da = try? fm.attributesOfItem(atPath: mac.path),
              let db = try? fm.attributesOfItem(atPath: disco.path),
              (da[.type] as? FileAttributeType) == .typeRegular,
              (db[.type] as? FileAttributeType) == .typeRegular
        else { return false }
        let sa = (da[.size] as? NSNumber)?.int64Value ?? -1
        let sb = (db[.size] as? NSNumber)?.int64Value ?? -2
        // Si los tamaños ya no cuadran, no hay nada que leer: son distintos, y
        // además el del Mac ha cambiado desde que se planificó.
        guard sa == sb, sa == size else { return false }
        return sameContents(mac, disco)
    }

    /// Compara dos archivos por trozos, sin cargarlos enteros en memoria.
    ///
    /// Por trozos y no de una: un vídeo de 20 GB leído entero se llevaría por
    /// delante la memoria de la máquina, y aquí lo normal es mover justo lo
    /// grande que ya no cabe en el Mac.
    private func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let fa = FileHandle(forReadingAtPath: a.path) else { return false }
        defer { try? fa.close() }
        guard let fb = FileHandle(forReadingAtPath: b.path) else { return false }
        defer { try? fb.close() }

        while true {
            if isCancelled { return false }
            let ta = fa.readData(ofLength: Self.chunkSize)
            let tb = fb.readData(ofLength: Self.chunkSize)
            if ta != tb { return false }
            if ta.isEmpty { return true }
        }
    }

    // MARK: Recorrer

    /// Lo que sale de recorrer una carpeta. Se devuelve entero en vez de ir
    /// escribiendo en el informe para que los dos lados se puedan recorrer a
    /// la vez sin pisarse.
    private struct ScanResult {
        var entries: [String: Entry] = [:]
        var errors: [String] = []
        var skipped: [String] = []
    }

    /// Lista recursiva de una carpeta, indexada por ruta relativa.
    ///
    /// No sigue enlaces simbólicos —los anota como tales— porque seguirlos es
    /// la forma clásica de copiar el disco entero sin querer, o de entrar en
    /// un bucle infinito con un enlace que apunta a su propio padre.
    ///
    /// - Parameter cloudKeys: preguntar por el estado de iCloud archivo a
    ///   archivo. Se paga aparte porque cuesta **dieciocho veces más** que
    ///   leer todo lo demás: esas dos claves no salen del sistema de archivos,
    ///   van a preguntarle al proceso de iCloud una vez por archivo. Sobre
    ///   veinte mil archivos son 0,9 s en vez de 0,05 s, y en una carpeta que
    ///   no está en iCloud la respuesta es siempre la misma.
    /// - Parameter skip: rutas relativas que no se miran ni se entra en ellas,
    ///   porque son de otra carpeta configurada. A diferencia de `matcher`,
    ///   que compara nombres sueltos, esto compara la ruta entera: saltarse
    ///   «otros» por el nombre se llevaría por delante todos los «otros» del
    ///   árbol, y aquí sólo sobra uno.
    private func scan(_ base: URL, matcher: ExcludeMatcher, cloudKeys: Bool,
                      skip: Set<String> = []) -> ScanResult {
        var out = ScanResult()
        var keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        if cloudKeys { keys += [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey] }

        // Los errores del recorrido se recogen aparte: el `errorHandler`
        // sobrevive a esta llamada y no puede escribir en algo prestado.
        var problemas: [String] = []
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: keys,
                                     options: [], errorHandler: { url, err in
            problemas.append(L("No se pudo leer %1$@: %2$@", url.lastPathComponent, err.localizedDescription))
            return true      // seguir con el resto
        }) else {
            out.errors += problemas
            return out
        }
        defer { out.errors += problemas }

        let basePath = base.resolvingSymlinksInPath().path
        var cacheDePadres: [String: String] = [:]
        while let url = en.nextObject() as? URL {
            if isCancelled { return out }
            let name = url.lastPathComponent
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else {
                // Un enlace simbólico roto llega hasta aquí: casi todas las
                // claves de `resourceValues` siguen el enlace, y si al otro
                // lado no hay nada, la consulta entera falla. `attributesOfItem`
                // usa lstat y sí lo ve, así que el enlace se registra como lo
                // que es y se copia como los demás, en vez de desaparecer del
                // backup sin decir nada.
                if !matcher.matches(name),
                   let at = try? fm.attributesOfItem(atPath: url.path),
                   (at[.type] as? FileAttributeType) == .typeSymbolicLink,
                   let rel = relativePath(of: url, under: basePath, cache: &cacheDePadres),
                   !skip.contains(rel) {
                    out.entries[rel] = Entry(rel: rel, isDir: false, isSymlink: true, size: 0,
                                             mtime: (at[.modificationDate] as? Date) ?? .distantPast,
                                             linkTarget: try? fm.destinationOfSymbolicLink(atPath: url.path))
                }
                continue
            }
            let isDir = v.isDirectory ?? false

            if matcher.matches(name) {
                if isDir { en.skipDescendants() }
                continue
            }

            guard let rel = relativePath(of: url, under: basePath, cache: &cacheDePadres) else { continue }

            // Otra carpeta configurada, que se lleva sola: ni se copia desde
            // aquí ni —lo que de verdad importa— se retira desde aquí al
            // recorrer el lado del disco. Se mira antes que iCloud porque
            // preguntar por lo que vamos a saltar sería pagar por nada.
            if skip.contains(rel) {
                if isDir { en.skipDescendants() }
                continue
            }

            // iCloud: un archivo que sólo está en la nube pesa 0 en disco y
            // abrirlo dispara la descarga. Copiar la carpeta entera se
            // convertiría en bajar iCloud completo por sorpresa, con el disco
            // externo esperando y la barra de progreso parada.
            //
            // En una carpeta en modo mover, además, saltárselo es lo que evita
            // que se borre del Mac algo que nunca llegó a copiarse.
            if cloudKeys, v.isUbiquitousItem == true,
               let st = v.ubiquitousItemDownloadingStatus, st != .current {
                out.skipped.append(L("%@ — está en iCloud sin descargar", name))
                if isDir { en.skipDescendants() }
                continue
            }

            let esEnlace = v.isSymbolicLink ?? false
            out.entries[rel] = Entry(
                rel: rel,
                isDir: isDir,
                isSymlink: esEnlace,
                size: Int64(v.fileSize ?? 0),
                mtime: v.contentModificationDate ?? .distantPast,
                linkTarget: esEnlace ? try? fm.destinationOfSymbolicLink(atPath: url.path) : nil
            )
        }
        return out
    }

    /// Ruta de `url` relativa a `base`, o `nil` si no cuelga de ella.
    ///
    /// Aquí no vale `standardizedFileURL`: en una ruta que atraviesa un enlace
    /// —`/tmp` y `/var` lo son en macOS— normaliza `/private/var/…` a `/var/…`
    /// sólo cuando la ruta existe de verdad. Un enlace simbólico roto, que no
    /// resuelve a ninguna parte, salía entonces con `/private/var/…` mientras
    /// su carpeta salía con `/var/…`: el prefijo no casaba y el archivo
    /// **desaparecía del recorrido sin dar ningún error**, que es exactamente
    /// el fallo que un backup no se puede permitir.
    ///
    /// Se resuelve la carpeta que lo contiene —nunca el archivo en sí, que
    /// puede ser el enlace que queremos copiar tal cual— y el resultado se
    /// guarda, porque el recorrido pasa por la misma carpeta una vez por cada
    /// archivo que hay dentro.
    private func relativePath(of url: URL, under base: String, cache: inout [String: String]) -> String? {
        let padre = url.deletingLastPathComponent()
        let resuelto: String
        if let visto = cache[padre.path] {
            resuelto = visto
        } else {
            resuelto = padre.resolvingSymlinksInPath().path
            cache[padre.path] = resuelto
        }
        let full = (resuelto as NSString).appendingPathComponent(url.lastPathComponent)
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    // MARK: Decidir

    /// Decide qué hay que hacer comparando los dos lados.
    ///
    /// Los ordenamientos van sobre la profundidad ya calculada y no sobre
    /// `depth(accion)`: `sort` llama al comparador del orden de n·log n veces,
    /// y calcularla dentro obligaba a partir la ruta en trocitos otras tantas
    /// —unas 300.000 veces para 20.000 archivos, para averiguar 20.000 datos.
    private func makePlan(source: [String: Entry], destination: [String: Entry],
                          report: inout SyncReport) -> [Action] {
        var carpetas: [(profundidad: Int, rel: String)] = []
        var copias: [(rel: String, accion: Action)] = []

        for (rel, e) in source {
            if e.isDir && !e.isSymlink {
                // Las carpetas primero y de menos honda a más honda: crear el
                // padre antes que el hijo.
                if destination[rel] == nil { carpetas.append((depth(of: rel), rel)) }
                continue
            }
            guard !e.isDir else { continue }

            if e.isSymlink {
                // Un enlace que ya está y apunta al mismo sitio no se toca:
                // rehacerlos todos en cada pasada funcionaría, pero llenaría
                // el registro de trabajo que nadie ha pedido.
                let d = destination[rel]
                if d?.isSymlink != true || d?.linkTarget != e.linkTarget {
                    copias.append((rel, .link(rel: rel)))
                } else {
                    report.unchanged += 1
                }
                continue
            }
            guard let d = destination[rel], !d.isDir, !d.isSymlink else {
                copias.append((rel, .copy(rel: rel, size: e.size, mtime: e.mtime, isNew: true))); continue
            }
            if e.size != d.size || abs(e.mtime.timeIntervalSince(d.mtime)) > Self.mtimeTolerance {
                copias.append((rel, .copy(rel: rel, size: e.size, mtime: e.mtime, isNew: false)))
            } else {
                report.unchanged += 1
            }
        }

        // Lo que sobra en el disco, de más honda a menos honda: vaciar la
        // carpeta antes de retirarla.
        var sobras: [(profundidad: Int, accion: Action)] = []
        for (rel, d) in destination where source[rel] == nil {
            sobras.append((depth(of: rel), .retire(rel: rel, isDir: d.isDir)))
        }

        carpetas.sort { $0.profundidad < $1.profundidad }
        copias.sort { $0.rel < $1.rel }           // orden estable = registro legible
        sobras.sort { $0.profundidad > $1.profundidad }

        return carpetas.map { Action.makeDir(rel: $0.rel) }
            + copias.map(\.accion)
            + sobras.map(\.accion)
    }

    /// El plan de una carpeta en modo mover: todo lo que hay en el Mac se
    /// lleva al disco.
    ///
    /// No hace falta el otro lado. No se compara nada, porque no se trata de
    /// dejar los dos iguales sino de vaciar uno dentro del otro, y no se
    /// retira nada nunca: lo que ya esté en el disco se queda, que para eso se
    /// llevó allí. Lo que hay que decidir archivo a archivo —si ya existe uno
    /// con ese nombre— se decide al escribir, mirando el disco en ese momento.
    ///
    /// Las carpetas se crean en el destino igual que en el modo sincronizar, y
    /// **ninguna se borra del Mac**: el esqueleto se queda vacío, tal cual,
    /// listo para volver a llenarse.
    private func makeMovePlan(source: [String: Entry]) -> [Action] {
        var carpetas: [(profundidad: Int, rel: String)] = []
        var archivos: [(rel: String, accion: Action)] = []

        for (rel, e) in source {
            if e.isDir && !e.isSymlink {
                carpetas.append((depth(of: rel), rel))
            } else {
                archivos.append((rel, .move(rel: rel, size: e.size, mtime: e.mtime, isSymlink: e.isSymlink)))
            }
        }

        carpetas.sort { $0.profundidad < $1.profundidad }
        archivos.sort { $0.rel < $1.rel }
        return carpetas.map { Action.makeDir(rel: $0.rel) } + archivos.map(\.accion)
    }

    /// Cuántas carpetas de hondura tiene una ruta relativa. Se cuentan las
    /// barras sin trocear la cadena, que es lo mismo y no reserva memoria.
    private func depth(of rel: String) -> Int {
        var n = 1
        for c in rel.utf8 where c == UInt8(ascii: "/") { n += 1 }
        return n
    }

    private func relOf(_ a: Action) -> String {
        switch a {
        case .copy(let r, _, _, _): return r
        case .move(let r, _, _, _): return r
        case .makeDir(let r):    return r
        case .link(let r):       return r
        case .retire(let r, _):  return r
        }
    }

    // MARK: Escribir

    /// Copia a un archivo temporal al lado y sólo entonces lo pone en su
    /// sitio.
    ///
    /// Es la diferencia entre un backup y un montón de archivos: si el disco
    /// se desconecta a mitad de una copia, lo que queda es un `.parcial`
    /// evidente, y no un archivo con el nombre bueno y la mitad del contenido,
    /// que es lo que de verdad hace daño porque parece correcto.
    /// - Returns: si el archivo cambió mientras se copiaba, en cuyo caso lo
    ///   que ha quedado en el disco no es de fiar y se ha marcado para
    ///   rehacerlo en la próxima pasada.
    @discardableResult
    private func copyAtomically(from: URL, to: URL, size: Int64 = 0, mtime: Date? = nil) throws -> Bool {
        let dir = to.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tmp = dir.appendingPathComponent(".\(to.lastPathComponent).bssd-parcial")
        try? fm.removeItem(at: tmp)

        do {
            // Los archivos grandes se copian a cachos para poder parar en
            // medio. `copyItem` es más rápido, pero una vez lanzado no hay
            // forma de interrumpirlo: con una película de 20 GB, «detener y
            // expulsar» se quedaría esperando minutos con el disco escribiendo
            // y el usuario mirando. Para lo pequeño no compensa: ahí el bucle
            // sólo añadiría trabajo.
            if size >= Self.streamingThreshold {
                try copyInChunks(from: from, to: tmp)
            } else {
                try fm.copyItem(at: from, to: tmp)
            }
        } catch {
            try? fm.removeItem(at: tmp)     // no dejar el trozo a medias
            throw error
        }

        // La fecha se conserva a mano: es lo que hace que la próxima
        // sincronización reconozca el archivo como igual en lugar de volver a
        // copiarlo. `copyItem` la respeta, pero no cuesta nada asegurarlo.
        //
        // Y se pone **la que tenía cuando se miró**, no la que tenga ahora.
        // Parece un detalle y es justo lo contrario: si alguien estaba
        // guardando el archivo mientras lo copiábamos, lo que ha ido al disco
        // es medio archivo viejo y medio nuevo. Sellándolo con la fecha nueva,
        // la próxima pasada lo daría por bueno y esa copia rota se quedaría
        // ahí para siempre. Con la vieja, el original ya no coincide y se
        // vuelve a copiar entero.
        if let m = mtime {
            try? fm.setAttributes([.modificationDate: m], ofItemAtPath: tmp.path)
        } else if let attrs = try? fm.attributesOfItem(atPath: from.path),
                  let m = attrs[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: m], ofItemAtPath: tmp.path)
        }

        if fm.fileExists(atPath: to.path) {
            _ = try fm.replaceItemAt(to, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: to)
        }

        // ¿Le han dado a guardar mientras copiábamos?
        guard let esperada = mtime, changedWhileCopying(from, expected: size, esperada) else {
            return false
        }
        // Entonces lo que hay en el disco es medio archivo de antes y medio de
        // después. Se le pone una fecha que no pueda confundirse con la buena:
        // dejarle la vieja no bastaría, porque si el guardado ocurrió medio
        // segundo después, los dos segundos de tolerancia de exFAT harían que
        // la próxima pasada los viera iguales y la copia rota se quedaría ahí
        // para siempre. Restando algo más que la tolerancia, la diferencia es
        // segura y el archivo se copia entero la próxima vez.
        let marcaEvidente = esperada.addingTimeInterval(-(Self.mtimeTolerance + 1))
        try? fm.setAttributes([.modificationDate: marcaEvidente], ofItemAtPath: to.path)
        return true
    }

    /// Si el archivo cambió mientras se copiaba.
    ///
    /// No hay forma de copiar «en un instante» un archivo que otro programa
    /// está escribiendo, así que lo que se puede hacer es enterarse: se mira
    /// el tamaño y la fecha al terminar y se comparan con los de antes de
    /// empezar. Es lo mismo que hace rsync, y por lo mismo.
    ///
    /// La comparación es exacta, sin la tolerancia de dos segundos que se usa
    /// para comparar los dos lados: aquí se mira el mismo archivo, en el mismo
    /// disco, con la misma precisión, dos veces seguidas. Con la tolerancia
    /// puesta, guardar el archivo medio segundo después de haberlo leído no se
    /// notaba, que es justo lo que pasa cuando alguien está trabajando.
    private func changedWhileCopying(_ url: URL, expected size: Int64, _ mtime: Date) -> Bool {
        guard let at = try? fm.attributesOfItem(atPath: url.path) else { return false }
        let ahoraSize = (at[.size] as? NSNumber)?.int64Value ?? size
        let ahoraMtime = (at[.modificationDate] as? Date) ?? mtime
        return ahoraSize != size || ahoraMtime != mtime
    }

    /// A partir de este tamaño se copia a cachos, para poder abortar a medias.
    /// 64 MB: por debajo, cualquier disco lo despacha en un momento.
    static let streamingThreshold: Int64 = 64 * 1024 * 1024
    /// Trozos de 4 MB: bastante grande para que el disco vaya a gusto y
    /// bastante pequeño para reaccionar enseguida a un «detener».
    static let chunkSize = 4 * 1024 * 1024

    /// Copia leyendo y escribiendo por trozos, mirando entre uno y otro si se
    /// ha pedido parar.
    private func copyInChunks(from: URL, to: URL) throws {
        guard let entrada = FileHandle(forReadingAtPath: from.path) else {
            throw SyncError.nested(L("No se pudo abrir %@.", from.lastPathComponent))
        }
        guard fm.createFile(atPath: to.path, contents: nil),
              let salida = FileHandle(forWritingAtPath: to.path) else {
            try? entrada.close()
            throw SyncError.nested(L("No se pudo escribir %@.", to.lastPathComponent))
        }
        defer { try? entrada.close(); try? salida.close() }

        while true {
            if isCancelled { throw SyncError.stopped }
            let trozo = entrada.readData(ofLength: Self.chunkSize)
            if trozo.isEmpty { break }
            try salida.write(contentsOf: trozo)
        }
    }

    private func copySymlink(from: URL, to: URL) throws {
        let dir = to.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let target = try fm.destinationOfSymbolicLink(atPath: from.path)
        // `fileExists` sigue el enlace, así que un enlace roto diría que no
        // existe y `createSymbolicLink` fallaría con «ya existe».
        if (try? fm.attributesOfItem(atPath: to.path)) != nil {
            try fm.removeItem(at: to)
        }
        try fm.createSymbolicLink(atPath: to.path, withDestinationPath: target)
    }

    /// Aparta un archivo o carpeta a `_Retirados/fecha/…` conservando su ruta.
    private func retire(_ victim: URL, to: URL) throws {
        let dir = to.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Caso corriente al retirar una carpeta entera: sus archivos se han
        // apartado antes —el plan va de lo más hondo a lo menos—, así que en
        // `_Retirados` ya existe una carpeta con este mismo nombre. Lo que
        // toca entonces es fundir la que queda con la que hay, no crear una
        // «Fotos-2» al lado que partiría la carpeta retirada en dos.
        // `fileExists` sigue los enlaces, así que un enlace a una carpeta se
        // haría pasar por carpeta: se retirarían uno a uno los archivos a los
        // que apunta —que están en otro sitio del backup y no sobran— en vez
        // del enlace, que es lo único que se ha borrado en el Mac.
        var esDir: ObjCBool = false
        if !isSymlink(victim), fm.fileExists(atPath: victim.path, isDirectory: &esDir), esDir.boolValue {
            var destDir: ObjCBool = false
            if fm.fileExists(atPath: to.path, isDirectory: &destDir), destDir.boolValue {
                for hijo in (try? fm.contentsOfDirectory(atPath: victim.path)) ?? [] {
                    try? retire(victim.appendingPathComponent(hijo),
                                to: to.appendingPathComponent(hijo))
                }
                try fm.removeItem(at: victim)     // ya vacía
                return
            }
        }

        var destino = to
        var n = 2
        // Mismo archivo retirado dos veces el mismo día (se borró, se
        // recuperó, se volvió a borrar): no se pisa el primero. Se mira con
        // `attributesOfItem` y no con `fileExists` porque el primer retirado
        // puede ser un enlace roto, que existe pero no lo parece.
        while (try? fm.attributesOfItem(atPath: destino.path)) != nil {
            let ext = to.pathExtension
            let base = to.deletingPathExtension().lastPathComponent
            let nombre = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            destino = dir.appendingPathComponent(nombre)
            n += 1
        }
        try fm.moveItem(at: victim, to: destino)
    }

    /// Si es un enlace simbólico, mirándolo a él y no a donde apunta.
    private func isSymlink(_ url: URL) -> Bool {
        let t = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return t == .typeSymbolicLink
    }

    /// Borra las carpetas de `_Retirados` más viejas que `days`.
    private func purgeOldRetired(root: URL, days: Int, report: inout SyncReport) -> Int {
        let base = root.appendingPathComponent("_Retirados", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(atPath: base.path) else { return 0 }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        let limite = Date().addingTimeInterval(-Double(days) * 86400)

        var n = 0
        for d in dirs {
            guard let fecha = df.date(from: d), fecha < limite else { continue }
            do { try fm.removeItem(at: base.appendingPathComponent(d)); n += 1 }
            catch { report.errors.append(L("No se pudo purgar _Retirados/%1$@: %2$@", d, error.localizedDescription)) }
        }
        return n
    }

    // MARK: Comprobaciones

    /// Ni el destino dentro del origen ni el origen dentro del destino.
    ///
    /// Lo primero es una copia infinita: cada pasada mete la copia dentro de
    /// la copia. Lo segundo haría que el motor «retirase» los archivos
    /// originales por no encontrarlos donde no están.
    private func assertNotNested(source: String, destination: URL) throws {
        let s = URL(fileURLWithPath: source).standardizedFileURL.path
        let d = destination.standardizedFileURL.path
        if d.hasPrefix(s + "/") || d == s {
            throw SyncError.nested(L("El destino %1$@ está dentro del origen %2$@: sería una copia sin fin.", d, s))
        }
        if s.hasPrefix(d + "/") {
            throw SyncError.nested(L("El origen %1$@ está dentro del destino %2$@.", s, d))
        }
    }

    /// Si la carpeta vive en iCloud, y por tanto merece la pena preguntar por
    /// cada archivo si está descargado.
    ///
    /// Se mira una vez por carpeta configurada, no una vez por archivo. Lo
    /// segundo es lo que hacía que comparar tardase dieciocho veces más de lo
    /// necesario en carpetas que no tienen nada que ver con iCloud.
    private func isInICloud(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return true
        }
        // Con «Escritorio y Documentos en iCloud», ~/Documents es en realidad
        // una ruta dentro de Mobile Documents, y la carpeta de arriba puede no
        // venir marcada.
        return url.resolvingSymlinksInPath().path.contains("/Mobile Documents/")
    }

    private func freeSpace(at url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }

    static func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        return df.string(from: Date())
    }
}

// MARK: - Exclusiones

/// Compara nombres —no rutas— contra patrones con `*` al principio o al final.
struct ExcludeMatcher {
    private let exact: Set<String>
    private let prefixes: [String]      // «tmp*»
    private let suffixes: [String]      // «*.pyc»

    init(patterns: [String]) {
        var e = Set<String>(); var p: [String] = []; var s: [String] = []
        for raw in patterns {
            let pat = raw.trimmingCharacters(in: .whitespaces)
            guard !pat.isEmpty else { continue }
            if pat.hasPrefix("*") && pat.count > 1 { s.append(String(pat.dropFirst())) }
            else if pat.hasSuffix("*") && pat.count > 1 { p.append(String(pat.dropLast())) }
            else { e.insert(pat) }
        }
        exact = e; prefixes = p; suffixes = s
    }

    func matches(_ name: String) -> Bool {
        if exact.contains(name) { return true }
        for s in suffixes where name.hasSuffix(s) { return true }
        for p in prefixes where name.hasPrefix(p) { return true }
        return false
    }
}

// MARK: - Formato

func fmtBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: n)
}
