// El estado de la app: qué disco hay, qué se está haciendo y qué pasó la
// última vez. La interfaz no hace más que mirar esto y pulsar sus botones.
//
// Toda la lógica de qué se copia está en SyncEngine, y toda la de qué disco es
// el bueno está en Volumes. Aquí sólo se decide *cuándo*.

import AppKit
import Combine
import Foundation

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
    @Published private(set) var history: [HistoryEntry] = []
    /// Todos los discos conectados ahora mismo, estén configurados o no: de
    /// aquí salen los que se ofrecen para añadir en los ajustes.
    @Published private(set) var volumes: [VolumeInfo] = []
    /// Lo último que ha dicho el motor, para la ventana.
    @Published private(set) var log: [String] = []

    /// El estado de los discos que están *haciendo* algo o que han fallado. Los
    /// demás no se guardan: su estado se deduce de si están conectados, y así
    /// no hay dos versiones de la verdad que puedan desdecirse.
    @Published private(set) var statuses: [UUID: SyncStatus] = [:]
    /// El disco que se está copiando ahora mismo, si hay alguno.
    @Published private(set) var working: UUID?
    /// Los que esperan turno, en orden.
    @Published private(set) var queued: [UUID] = []
    /// Los que se están expulsando.
    @Published private(set) var ejecting: Set<UUID> = []
    /// El disco que se está mirando en la ventana y en los ajustes. Es uno solo
    /// para las dos, porque tener abierta la ventana con un disco y los ajustes
    /// con otro es la mejor forma de cambiarle las carpetas al que no era.
    @Published var selectedDiskID: UUID?

    private let watcher = VolumeWatcher()
    private var engine: SyncEngine?
    private let queue = DispatchQueue(label: "es.backupssd.motor", qos: .utility)
    /// Aparte de la del motor, que es serial: mirar los discos mientras se
    /// está copiando tendría que esperar a que acabase la copia entera.
    private let discosQueue = DispatchQueue(label: "es.backupssd.discos", qos: .userInitiated)
    /// Cuándo se sincronizó por última vez con éxito, **por disco**. Evita que
    /// desenchufar y volver a enchufar dos veces seguidas dispare tres copias,
    /// y por disco y no en general porque el minuto de gracia de uno no tiene
    /// por qué frenar al otro.
    private var lastAutoSync: [UUID: Date] = [:]

    /// Un turno en la cola. Se apunta el ensayo igual que la copia de verdad:
    /// los dos leen los mismos discos a la vez y estorbarían si coincidieran.
    private struct Turno { let disk: UUID; let dryRun: Bool }
    private var cola: [Turno] = []

    init() {
        config = Config.load()
        history = History.load()
        selectedDiskID = config.disks.first?.id
        // Si venía del archivo de un solo disco, se deja escrito ya en el
        // formato de ahora. Si no, cada arranque volvería a convertirlo, y la
        // copia de `load()` no tendría con qué compararse.
        if config.migratedFromV1 { config.save() }

        watcher.onMount = { [weak self] vol in self?.handleMount(vol) }
        watcher.onUnmount = { [weak self] url in self?.handleUnmount(url) }
        watcher.start()
        watcher.announceAlreadyMounted()
        reloadVolumes()
    }

    // MARK: Discos

    /// El volumen de un disco configurado, si está puesto ahora mismo.
    func volume(of disk: DiskProfile) -> VolumeInfo? {
        guard !disk.volumeUUID.isEmpty else { return nil }
        return volumes.first { $0.uuid == disk.volumeUUID }
    }

    func isConnected(_ disk: DiskProfile) -> Bool { volume(of: disk) != nil }

    /// El estado de un disco. Los que no están en `statuses` no están haciendo
    /// nada, así que basta con mirar si están puestos.
    func status(of disk: DiskProfile) -> SyncStatus {
        if let s = statuses[disk.id] { return s }
        if let v = volume(of: disk) { return .listo(volumen: v.name) }
        return .sinDisco
    }

    /// El estado de todo junto, que es lo que dice el icono de la barra: manda
    /// lo que está pasando ahora, luego lo que ha fallado, y sólo si no hay
    /// nada de eso, si queda algún disco puesto.
    var status: SyncStatus {
        if let w = working, let s = statuses[w] { return s }
        for d in config.disks {
            if case .fallo = status(of: d) { return status(of: d) }
        }
        if let puesto = config.disks.first(where: { isConnected($0) }) {
            return .listo(volumen: volume(of: puesto)?.name ?? puesto.volumeName)
        }
        return .sinDisco
    }

    private func handleMount(_ vol: VolumeInfo) {
        // Antes de mirar si es de los nuestros: cualquier montaje cambia la
        // lista que se ofrece en los ajustes.
        reloadVolumes()
        // `volumes` se rellena en otra cola, así que aquí se añade a mano: lo
        // que viene a continuación pregunta si el disco está conectado, y la
        // respuesta tiene que ser sí desde ya.
        if !volumes.contains(where: { $0.uuid == vol.uuid }) { volumes.append(vol) }
        guard let disk = config.disk(uuid: vol.uuid) else { return }

        // El nombre puede haber cambiado desde que se eligió; se refresca para
        // que la interfaz no siga llamándolo como ya no se llama.
        if disk.volumeName != vol.name {
            config[disk.id]?.volumeName = vol.name
        }
        // Un fallo de la vez pasada no tiene por qué seguir en pantalla ahora
        // que el disco vuelve a estar puesto.
        if case .fallo = statuses[disk.id] ?? .sinDisco { statuses[disk.id] = nil }

        guard disk.autoSyncOnMount else { return }
        // Un minuto de gracia: enchufar, que el Finder abra la ventana y que
        // el disco se asiente. Sincronizar en el mismo instante del montaje
        // compite con Spotlight indexando y con el propio sistema.
        if let ultima = lastAutoSync[disk.id], Date().timeIntervalSince(ultima) < 60 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let d = self.config[disk.id], self.isConnected(d) else { return }
            self.lastAutoSync[disk.id] = Date()
            self.sync(d)
        }
    }

    private func handleUnmount(_ url: URL) {
        volumes.removeAll { $0.url == url }
        reloadVolumes()
        // Sólo se cancela si el que se va es el que se está copiando: con
        // varios discos puestos, desenchufar uno no puede abortar la copia de
        // otro. El motor comprueba la cancelación entre archivo y archivo, así
        // que deja de escribir en vez de acumular errores.
        if let w = working, let disk = config[w], !isConnected(disk) {
            engine?.cancel()
        }
        // Los que esperaban turno y ya no están se caen de la cola solos, al
        // llegarles el turno.
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

    // MARK: Sincronizar

    func canSync(_ disk: DiskProfile) -> Bool {
        isConnected(disk) && !isBusy(disk) && config.problems(of: disk).isEmpty
    }

    /// Está copiando o esperando turno: en los dos casos, no se vuelve a pedir.
    func isBusy(_ disk: DiskProfile) -> Bool {
        working == disk.id || cola.contains { $0.disk == disk.id }
    }

    /// Pone un disco en la cola. Si no hay nadie copiando, empieza en el acto.
    ///
    /// Nunca dos a la vez, y no por prudencia: dos copias comparten el bus USB
    /// y la memoria del Mac, y a la vez irían las dos más lentas que en fila.
    func sync(_ disk: DiskProfile, dryRun: Bool = false) {
        guard !isBusy(disk) else { return }
        cola.append(Turno(disk: disk.id, dryRun: dryRun))
        queued = cola.map(\.disk)
        arrancarSiguiente()
    }

    /// Sincroniza todos los que estén puestos y en condiciones.
    func syncAll() {
        for d in config.disks where canSync(d) { sync(d) }
    }

    private func arrancarSiguiente() {
        guard working == nil else { return }

        // En bucle y no llamándose a sí misma: un disco que falla al arrancar
        // —se lo han llevado mientras esperaba— no gasta un nivel de pila por
        // cada uno de los que quedan detrás.
        while !cola.isEmpty {
            let turno = cola.removeFirst()
            queued = cola.map(\.disk)

            guard let disk = config[turno.disk] else { continue }

            let problemas = config.problems(of: disk)
            guard problemas.isEmpty else {
                fallar(disk, problemas.joined(separator: " "))
                continue
            }
            let root: URL
            do { root = try Volumes.backupRoot(config: disk) }
            catch { fallar(disk, error.localizedDescription); continue }

            arrancar(disk, root: root, dryRun: turno.dryRun)
            return
        }
    }

    private func arrancar(_ disk: DiskProfile, root: URL, dryRun: Bool) {
        let motor = SyncEngine()
        engine = motor
        working = disk.id
        statuses[disk.id] = .comparando
        log = []

        let id = disk.id
        let cfg = disk
        let nombre = volume(of: disk)?.name ?? disk.volumeName

        motor.onProgress = { [weak self] hechos, total, actual in
            DispatchQueue.main.async {
                guard let self, self.working == id else { return }
                self.statuses[id] = total > 0
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
                        self.statuses[id] = nil
                        self.terminar(id)
                    } else {
                        self.finish(report: r, disk: id, volume: nombre)
                    }
                case .failure(let e):
                    self.finish(failure: e.localizedDescription, disk: id, volume: nombre)
                }
                self.engine = nil
            }
        }
    }

    /// Ha acabado el turno de este disco: se expulsa si se había pedido y entra
    /// el siguiente de la cola.
    private func terminar(_ id: UUID) {
        working = nil
        ejectIfPending(id)
        arrancarSiguiente()
    }

    /// Un disco que ni llega a arrancar. Se apunta igual en el historial: que
    /// no se pudiera empezar es justo lo que hay que poder mirar después.
    private func fallar(_ disk: DiskProfile, _ mensaje: String) {
        finish(failure: mensaje, disk: disk.id,
               volume: volume(of: disk)?.name ?? disk.volumeName)
    }

    func cancel() { engine?.cancel() }

    /// Saca de la cola a uno que todavía no ha empezado.
    func dequeue(_ disk: DiskProfile) {
        cola.removeAll { $0.disk == disk.id }
        queued = cola.map(\.disk)
    }

    // MARK: Expulsar

    /// Parar lo que se esté haciendo con ese disco y soltarlo para poder
    /// llevárselo.
    ///
    /// Tirar del cable a mitad de una copia es lo que deja archivos cortados,
    /// y aunque el motor escribe a un temporal para que eso no estropee el
    /// backup, el disco puede quedar tocado. Así que hay una forma de decirlo:
    /// se cancela, se espera a que el archivo que estaba en marcha termine, y
    /// entonces se desmonta de verdad.
    func stopAndEject(_ disk: DiskProfile) {
        guard let vol = volume(of: disk) else { return }
        // Si sólo estaba esperando turno, no hay nada que parar: se le quita
        // el turno y se expulsa.
        dequeue(disk)
        if working == disk.id {
            ejecting.insert(disk.id)
            append(log: L("Parando para expulsar el disco…"))
            cancel()
            return      // la expulsión la remata `terminar(...)` al acabar
        }
        eject(disk.id, vol)
    }

    private func eject(_ id: UUID, _ vol: VolumeInfo) {
        ejecting.insert(id)
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
                self.ejecting.remove(id)
                if let f = fallo {
                    // Lo normal aquí es que otra app tenga un archivo abierto
                    // en el disco. Se dice tal cual, que es lo que hay que
                    // arreglar antes de volver a intentarlo.
                    self.statuses[id] = .fallo(L("No se pudo expulsar %1$@: %2$@", nombre, f))
                    self.append(log: "⚠︎ " + L("No se pudo expulsar %1$@: %2$@", nombre, f))
                } else {
                    self.append(log: L("%@ expulsado. Ya se puede desconectar.", nombre))
                    self.volumes.removeAll { $0.url == url }
                }
                self.reloadVolumes()
            }
        }
    }

    /// Si se pidió expulsar mientras se copiaba, se remata ahora.
    private func ejectIfPending(_ id: UUID) {
        guard ejecting.contains(id), let disk = config[id], let vol = volume(of: disk) else { return }
        ejecting.remove(id)
        eject(id, vol)
    }

    // MARK: Rematar

    private func finish(report: SyncReport, disk id: UUID, volume nombre: String) {
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
        statuses[id] = nil          // vuelve a deducirse de si está puesto
        terminar(id)
    }

    private func finish(failure: String, disk id: UUID, volume nombre: String) {
        let entrada = HistoryEntry(failure: failure, volume: nombre)
        history.insert(entrada, at: 0)
        History.save(history)
        append(log: "⚠︎ \(failure)")
        statuses[id] = .fallo(failure)
        terminar(id)
    }

    private func append(log linea: String) {
        log.append(linea)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: Cosas que pide la interfaz

    var lastSync: HistoryEntry? { history.first }

    /// El disco que se está mirando, o el primero que haya.
    var selectedDisk: DiskProfile? {
        if let id = selectedDiskID, let d = config[id] { return d }
        return config.disks.first
    }

    /// Lo último que se hizo con este disco, para enseñarlo en su ficha.
    func lastSync(of disk: DiskProfile) -> HistoryEntry? {
        history.first { $0.volumeName == disk.volumeName }
    }

    /// Añade un disco a la configuración. Uno por disco físico: si ese UUID ya
    /// está, se selecciona el que hay en vez de crear otro que se pisaría con
    /// él en cada pasada.
    @discardableResult
    func addDisk(_ vol: VolumeInfo) -> DiskProfile {
        if let ya = config.disk(uuid: vol.uuid) {
            selectedDiskID = ya.id
            return ya
        }
        var nuevo = DiskProfile()
        nuevo.volumeUUID = vol.uuid
        nuevo.volumeName = vol.name
        config.disks.append(nuevo)
        selectedDiskID = nuevo.id
        return nuevo
    }

    func removeDisk(_ id: UUID) {
        cola.removeAll { $0.disk == id }
        queued = cola.map(\.disk)
        statuses[id] = nil
        config.disks.removeAll { $0.id == id }
        if selectedDiskID == id { selectedDiskID = config.disks.first?.id }
    }

    func addFolder(_ url: URL, to id: UUID) {
        guard var disk = config[id] else { return }
        var nombre = url.lastPathComponent
        let usados = Set(disk.folders.map(\.name))
        var n = 2
        while usados.contains(nombre) { nombre = "\(url.lastPathComponent)-\(n)"; n += 1 }
        disk.folders.append(SyncFolder(source: url.path, name: nombre))
        config[id] = disk
    }

    func removeFolders(_ ids: Set<UUID>, from id: UUID) {
        config[id]?.folders.removeAll { ids.contains($0.id) }
    }

    func clearHistory() {
        history = []
        History.save(history)
    }
}
