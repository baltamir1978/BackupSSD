// El estado de la app: qué disco hay, qué se está haciendo y qué pasó la
// última vez. La interfaz no hace más que mirar esto y pulsar sus botones.
//
// Toda la lógica de qué se copia está en SyncEngine, y toda la de qué disco es
// el bueno está en Volumes. Aquí sólo se decide *cuándo*.

import AppKit
import Combine
import Foundation

// MARK: - Historial

/// Una sincronización que ya pasó. Se guarda en disco para que la respuesta a
/// «¿esto se copió?» no dependa de que la app siga abierta desde entonces.
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var volumeName = ""
    var copied = 0
    var updated = 0
    var retired = 0
    var moved = 0
    var errors: [String] = []
    /// Cuántos estaban en uso y se volverán a copiar.
    var changed = 0
    /// Cuántos se copiaron al disco pero **no** se borraron del Mac porque no
    /// se pudo comprobar que la copia estuviera bien.
    var unverified = 0
    var bytes: Int64 = 0
    var duration: TimeInterval = 0
    var cancelled = false
    /// Si no llegó a empezar: por qué.
    var failure: String? = nil

    init(report: SyncReport, volume: String) {
        volumeName = volume
        copied = report.copied
        updated = report.updated
        retired = report.retired
        moved = report.moved
        errors = report.errors
        changed = report.changed.count
        unverified = report.unverified.count
        bytes = report.bytesWritten
        duration = report.duration
        cancelled = report.cancelled
    }

    init(failure: String, volume: String) {
        self.failure = failure
        volumeName = volume
    }

    /// Clave a clave, por lo mismo que en `Config`: el `init(from:)` que
    /// sintetiza Swift usa `decode` y no mira los valores por omisión, así que
    /// una clave nueva —`moved`, sin ir más lejos— haría fallar la
    /// decodificación de **todo** el archivo. Como `History.load()` lo intenta
    /// con `try?`, el fallo no se vería: la app arrancaría con el historial en
    /// blanco y parecería que se ha perdido lo de todos estos meses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? ""
        copied = try c.decodeIfPresent(Int.self, forKey: .copied) ?? 0
        updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        retired = try c.decodeIfPresent(Int.self, forKey: .retired) ?? 0
        moved = try c.decodeIfPresent(Int.self, forKey: .moved) ?? 0
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        changed = try c.decodeIfPresent(Int.self, forKey: .changed) ?? 0
        unverified = try c.decodeIfPresent(Int.self, forKey: .unverified) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }

    var ok: Bool { failure == nil && errors.isEmpty && !cancelled }

    var summary: String {
        if let f = failure { return f }
        if cancelled { return L("Detenido — %@ copiados antes de parar", plural("%ld archivos", copied + updated + moved)) }
        var partes: [String] = []
        if copied > 0 { partes.append(plural("%ld nuevos", copied)) }
        if updated > 0 { partes.append(plural("%ld actualizados", updated)) }
        if moved > 0 { partes.append(plural("%ld movidos", moved)) }
        if retired > 0 { partes.append(plural("%ld retirados", retired)) }
        if partes.isEmpty { partes.append(L("sin cambios")) }
        if changed > 0 { partes.append(plural("%ld estaban en uso", changed)) }
        if unverified > 0 { partes.append(plural("%ld sin mover", unverified)) }
        if !errors.isEmpty { partes.append(plural("%ld con error", errors.count)) }
        return partes.joined(separator: ", ")
    }
}

enum History {
    static var fileURL: URL { Config.directory.appendingPathComponent("historial.json") }
    /// Suficiente para mirar atrás unos meses sin que el archivo crezca sin fin.
    static let limit = 100

    static func load() -> [HistoryEntry] {
        guard let d = try? Data(contentsOf: fileURL),
              let h = try? JSONDecoder().decode([HistoryEntry].self, from: d) else { return [] }
        return h
    }

    static func save(_ entries: [HistoryEntry]) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(Array(entries.prefix(limit))) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Estado

enum SyncStatus: Equatable {
    case sinDisco
    case listo(volumen: String)
    case comparando
    case copiando(hechos: Int, total: Int, actual: String)
    case fallo(String)

    var esTrabajando: Bool {
        switch self {
        case .comparando, .copiando: return true
        default: return false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var config: Config {
        didSet { config.save() }
    }
    @Published private(set) var status: SyncStatus = .sinDisco
    @Published private(set) var history: [HistoryEntry] = []
    /// El disco de la configuración, si está puesto ahora mismo.
    @Published private(set) var volume: VolumeInfo?
    /// Todos los discos conectados, para poder elegir uno en los ajustes.
    @Published private(set) var volumes: [VolumeInfo] = []
    /// Lo último que ha dicho el motor, para la ventana.
    @Published private(set) var log: [String] = []

    private let watcher = VolumeWatcher()
    private var engine: SyncEngine?
    private let queue = DispatchQueue(label: "es.backupssd.motor", qos: .utility)
    /// Aparte de la del motor, que es serial: mirar los discos mientras se
    /// está copiando tendría que esperar a que acabase la copia entera.
    private let discosQueue = DispatchQueue(label: "es.backupssd.discos", qos: .userInitiated)
    /// Cuándo se sincronizó por última vez con éxito, por disco. Evita que
    /// desenchufar y volver a enchufar dos veces seguidas dispare tres copias.
    private var lastAutoSync: Date?

    init() {
        config = Config.load()
        history = History.load()

        watcher.onMount = { [weak self] vol in self?.handleMount(vol) }
        watcher.onUnmount = { [weak self] url in self?.handleUnmount(url) }
        watcher.start()
        watcher.announceAlreadyMounted()
        reloadVolumes()
    }

    // MARK: Discos

    private func handleMount(_ vol: VolumeInfo) {
        // Antes de mirar si es *el* disco: cualquier montaje cambia la lista
        // que se ofrece en los ajustes.
        reloadVolumes()
        guard vol.uuid == config.volumeUUID, !config.volumeUUID.isEmpty else { return }
        volume = vol
        // El nombre puede haber cambiado desde que se eligió; se refresca para
        // que la interfaz no siga llamándolo como ya no se llama.
        if config.volumeName != vol.name {
            config.volumeName = vol.name
        }
        if case .fallo = status {} else { status = .listo(volumen: vol.name) }

        guard config.autoSyncOnMount else { return }
        // Un minuto de gracia: enchufar, que el Finder abra la ventana y que
        // el disco se asiente. Sincronizar en el mismo instante del montaje
        // compite con Spotlight indexando y con el propio sistema.
        if let ultima = lastAutoSync, Date().timeIntervalSince(ultima) < 60 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.volume?.uuid == vol.uuid, !self.status.esTrabajando else { return }
            self.lastAutoSync = Date()
            self.sync()
        }
    }

    private func handleUnmount(_ url: URL) {
        reloadVolumes()
        guard let vol = volume, vol.url == url || !FileManager.default.fileExists(atPath: vol.url.path) else { return }
        // Se cancela antes que nada: el motor comprueba esta bandera entre
        // archivo y archivo, y así deja de escribir en un disco que se está
        // yendo en vez de acumular errores.
        engine?.cancel()
        volume = nil
        if !status.esTrabajando { status = .sinDisco }
    }

    /// Relee los discos conectados **fuera del hilo principal**.
    ///
    /// Preguntarle a un volumen su UUID es leer del disco, y un disco dormido
    /// o una unidad de red tardan lo suyo en contestar. Hacerlo en la cola
    /// principal congelaba la ventana de ajustes justo mientras se elegía el
    /// disco, que es cuando peor sienta.
    func reloadVolumes() {
        discosQueue.async { [weak self] in
            let discos = Volumes.mounted()
            DispatchQueue.main.async { self?.volumes = discos }
        }
    }

    /// Vuelve a mirar qué hay puesto. Para después de cambiar de disco en los
    /// ajustes, cuando no ha habido ningún montaje del que enterarse.
    func refreshVolume() {
        if let v = Volumes.find(uuid: config.volumeUUID) {
            volume = v
            if !status.esTrabajando { status = .listo(volumen: v.name) }
        } else {
            volume = nil
            if !status.esTrabajando { status = .sinDisco }
        }
    }

    // MARK: Sincronizar

    var canSync: Bool { volume != nil && !status.esTrabajando && config.problems().isEmpty }

    func sync(dryRun: Bool = false) {
        guard !status.esTrabajando else { return }

        let problemas = config.problems()
        guard problemas.isEmpty else {
            finish(failure: problemas.joined(separator: " "))
            return
        }

        let root: URL
        do { root = try Volumes.backupRoot(config: config) }
        catch { finish(failure: error.localizedDescription); return }

        let motor = SyncEngine()
        engine = motor
        status = .comparando
        log = []

        let cfg = config
        let nombre = volume?.name ?? config.volumeName

        motor.onProgress = { [weak self] hechos, total, actual in
            DispatchQueue.main.async {
                guard let self, self.status.esTrabajando else { return }
                self.status = total > 0
                    ? .copiando(hechos: hechos, total: total, actual: actual)
                    : .comparando
            }
        }
        motor.onLog = { [weak self] linea in
            DispatchQueue.main.async { self?.append(log: linea) }
        }

        queue.async { [weak self] in
            let resultado: Result<SyncReport, Error>
            do { resultado = .success(try motor.run(config: cfg, root: root, dryRun: dryRun)) }
            catch { resultado = .failure(error) }

            DispatchQueue.main.async {
                guard let self else { return }
                switch resultado {
                case .success(let r):
                    // Un ensayo no es una sincronización: se enseña, pero no
                    // se apunta en el historial como si se hubiera copiado.
                    if dryRun {
                        self.append(log: L("Ensayo: %@", r.summary))
                        self.status = self.volume.map { .listo(volumen: $0.name) } ?? .sinDisco
                    } else {
                        self.finish(report: r, volume: nombre)
                    }
                case .failure(let e):
                    self.finish(failure: e.localizedDescription)
                }
                self.engine = nil
            }
        }
    }

    func cancel() { engine?.cancel() }

    // MARK: Expulsar

    /// Se ha pedido expulsar mientras se copiaba: en cuanto pare, se expulsa.
    @Published private(set) var ejecting = false

    /// Parar lo que se esté haciendo y soltar el disco para poder llevárselo.
    ///
    /// Tirar del cable a mitad de una copia es lo que deja archivos cortados,
    /// y aunque el motor escribe a un temporal para que eso no estropee el
    /// backup, el disco puede quedar tocado. Así que hay una forma de decirlo:
    /// se cancela, se espera a que el archivo que estaba en marcha termine, y
    /// entonces se desmonta de verdad.
    func stopAndEject() {
        guard let vol = volume else { return }
        if status.esTrabajando {
            ejecting = true
            append(log: L("Parando para expulsar el disco…"))
            cancel()
            return      // la expulsión la remata `finish(...)` al terminar
        }
        eject(vol)
    }

    private func eject(_ vol: VolumeInfo) {
        ejecting = true
        let url = vol.url
        let nombre = vol.name
        // Desmontar puede tardar —el sistema tiene que vaciar lo que aún no ha
        // escrito—, así que no se hace en la cola principal.
        discosQueue.async { [weak self] in
            var fallo: String? = nil
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            catch { fallo = error.localizedDescription }

            DispatchQueue.main.async {
                guard let self else { return }
                self.ejecting = false
                if let f = fallo {
                    // Lo normal aquí es que otra app tenga un archivo abierto
                    // en el disco. Se dice tal cual, que es lo que hay que
                    // arreglar antes de volver a intentarlo.
                    self.status = .fallo(L("No se pudo expulsar %1$@: %2$@", nombre, f))
                    self.append(log: "⚠︎ " + L("No se pudo expulsar %1$@: %2$@", nombre, f))
                } else {
                    self.append(log: L("%@ expulsado. Ya se puede desconectar.", nombre))
                    self.volume = nil
                    self.status = .sinDisco
                }
                self.reloadVolumes()
            }
        }
    }

    /// Si se pidió expulsar mientras se copiaba, se remata ahora.
    private func ejectIfPending() {
        guard ejecting, let vol = volume else { return }
        eject(vol)
    }

    private func finish(report: SyncReport, volume nombre: String) {
        let entrada = HistoryEntry(report: report, volume: nombre)
        history.insert(entrada, at: 0)
        History.save(history)
        for e in report.errors.prefix(20) { append(log: "⚠︎ \(e)") }
        for s in report.skipped.prefix(20) { append(log: L("· saltado: %@", s)) }
        // Merece la pena decirlo: son archivos que estaban abiertos y en uso,
        // y su copia se rehará sola la próxima vez.
        for c in report.changed.prefix(20) {
            append(log: L("· %@ estaba cambiando mientras se copiaba; se copiará otra vez la próxima vez", c))
        }
        for v in report.vanished.prefix(20) {
            append(log: L("· %@ desapareció antes de poder copiarlo", v))
        }
        // Esto hay que decirlo sí o sí: quien pone una carpeta en modo mover
        // espera encontrarla vacía, y si algo se ha quedado tiene que saber
        // cuál y por qué.
        for u in report.unverified.prefix(20) {
            append(log: "⚠︎ " + L("%@ no se pudo comprobar después de copiarlo; sigue en el Mac", u))
        }
        for r in report.renamed.prefix(20) {
            append(log: L("· ya había otro con ese nombre en el disco: %@", r))
        }
        append(log: entrada.summary)
        status = volume.map { .listo(volumen: $0.name) } ?? .sinDisco
        ejectIfPending()
    }

    private func finish(failure: String) {
        let entrada = HistoryEntry(failure: failure, volume: volume?.name ?? config.volumeName)
        history.insert(entrada, at: 0)
        History.save(history)
        append(log: "⚠︎ \(failure)")
        status = .fallo(failure)
        ejectIfPending()
    }

    private func append(log linea: String) {
        log.append(linea)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: Cosas que pide la interfaz

    var lastSync: HistoryEntry? { history.first }

    func chooseVolume(_ vol: VolumeInfo) {
        config.volumeUUID = vol.uuid
        config.volumeName = vol.name
        refreshVolume()
    }

    func addFolder(_ url: URL) {
        var nombre = url.lastPathComponent
        let usados = Set(config.folders.map(\.name))
        var n = 2
        while usados.contains(nombre) { nombre = "\(url.lastPathComponent)-\(n)"; n += 1 }
        config.folders.append(SyncFolder(source: url.path, name: nombre))
    }

    func removeFolders(_ ids: Set<UUID>) {
        config.folders.removeAll { ids.contains($0.id) }
    }

    func clearHistory() {
        history = []
        History.save(history)
    }
}
