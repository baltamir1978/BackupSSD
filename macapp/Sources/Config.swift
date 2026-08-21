// Configuración de Backup SSD: qué se copia, a qué disco y con qué reglas.
//
// Vive en ~/.config/backup-ssd/config.json y no en UserDefaults a propósito:
// es un archivo que se puede abrir, leer y corregir con un editor cuando algo
// va mal, y que se copia a otro Mac sin más ceremonia.

import Foundation

// MARK: - Qué se hace con una carpeta

/// Las dos formas de tratar una carpeta.
enum FolderMode: String, Codable, CaseIterable {
    /// El disco queda igual que el Mac: lo que se borra aquí se retira allí.
    case sync
    /// Lo que hay en el Mac se lleva al disco y se borra del Mac. Se **añade**
    /// a lo que ya hubiera en el destino y no se retira nada nunca: el disco
    /// es el archivo definitivo y el Mac, un buzón que se vacía.
    case move

    var label: String {
        switch self {
        case .sync: return L("Sincronizar")
        case .move: return L("Mover")
        }
    }

    var explanation: String {
        switch self {
        case .sync: return L("El disco queda igual que el Mac.")
        case .move: return L("Se lleva al disco y se borra del Mac.")
        }
    }
}

// MARK: - Carpeta que se sincroniza

/// Un origen del Mac y el nombre que tendrá su copia dentro del disco.
///
/// El nombre se guarda aparte del origen porque dos carpetas distintas pueden
/// llamarse igual (`~/Proyectos/docs` y `~/Trabajo/docs`): si el destino
/// saliera del último componente de la ruta, la segunda sobrescribiría a la
/// primera sin avisar.
struct SyncFolder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Ruta absoluta en el Mac. Se guarda expandida.
    var source: String
    /// Carpeta dentro del destino. Un solo componente, sin barras.
    ///
    /// Sólo se usa cuando la carpeta no cuelga de otra configurada. Si cuelga
    /// —`~/Documentos/otros` dentro de `~/Documentos`—, el destino sale de la
    /// de fuera y esto se queda como mera etiqueta para la interfaz. Ver
    /// `Config.destination(of:under:)`.
    var name: String
    var enabled: Bool = true
    /// Sincronizar (por omisión) o mover. Ver `FolderMode`.
    var mode: FolderMode = .sync

    init(source: String, name: String? = nil, enabled: Bool = true, mode: FolderMode = .sync) {
        let path = (source as NSString).expandingTildeInPath
        self.source = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.enabled = enabled
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey { case id, source, name, enabled, mode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = ((try c.decode(String.self, forKey: .source)) as NSString).expandingTildeInPath
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (source as NSString).lastPathComponent
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // Una configuración escrita antes de que existiera el modo «mover» no
        // trae la clave, y lo que había entonces era sincronizar. El valor por
        // omisión tiene que ser el que no borra nada del Mac.
        mode = try c.decodeIfPresent(FolderMode.self, forKey: .mode) ?? .sync
    }

    /// La ruta de destino de esta carpeta cuando no cuelga de ninguna otra.
    /// Para el caso general hay que pasar por `Config.destination(of:under:)`,
    /// que sabe de las demás carpetas.
    func destination(under root: URL) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// El origen con los enlaces simbólicos resueltos y sin barra final.
    ///
    /// Es la forma en la que hay que compararlo con otros orígenes para saber
    /// quién cuelga de quién: `~/Documents` es un enlace a Mobile Documents
    /// cuando se usa iCloud, y sin resolverlo la carpeta de dentro no parecería
    /// estar dentro. `SyncEngine.scan` recorre resolviendo igual, así que las
    /// rutas relativas que salen de aquí casan con las suyas.
    var resolvedSource: String {
        URL(fileURLWithPath: source).resolvingSymlinksInPath().path
    }
}

// MARK: - Apariencia

enum Appearance: String, Codable, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return L("Como el sistema")
        case .light:  return L("Claro")
        case .dark:   return L("Oscuro")
        }
    }
}

// MARK: - Configuración

struct Config: Codable {
    /// UUID del volumen de destino. **Es la clave de todo**: identificar el
    /// disco por su nombre sería temerario, porque dos discos pueden llamarse
    /// «Backup» y macOS monta el segundo como «Backup 1». Copiar al disco
    /// equivocado y, peor todavía, *retirar* del disco equivocado lo que no
    /// está en el Mac, es el peor fallo que puede tener un programa así.
    var volumeUUID: String = ""
    /// Solo para enseñarlo en la interfaz: «Se sincronizará al conectar SSD-T7».
    var volumeName: String = ""
    /// Carpeta raíz dentro del disco. Todo cuelga de aquí, para que el disco
    /// pueda tener además otras cosas que Backup SSD no toca jamás.
    var rootFolder: String = "Backup-SSD"

    var folders: [SyncFolder] = []

    /// Sincronizar en cuanto se monta el disco, sin preguntar.
    var autoSyncOnMount: Bool = true

    /// Lo que se borra del Mac no se borra del disco: se aparta a
    /// `_Retirados/AAAA-MM-DD/`. Es la red de seguridad ante un borrado
    /// accidental, y lo que separa esto de un espejo a secas.
    var keepRemoved: Bool = true
    /// Días que se guarda lo retirado antes de borrarlo de verdad. A 0, no se
    /// purga nunca.
    var removedRetentionDays: Int = 90

    /// Nombres que no se copian. Se comparan contra el nombre del archivo o
    /// de la carpeta, no contra la ruta entera, y admiten `*` al principio o
    /// al final. Van aquí y no fijos en el código porque cada uno tiene su
    /// propia basura que no quiere en el backup.
    var excludes: [String] = [
        ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
        "node_modules", ".build", ".pio", "__pycache__", "*.pyc",
        "build", "DerivedData", ".venv", "venv",
    ]

    /// Saltarse los archivos de iCloud que no están descargados en el disco.
    /// Ver `SyncEngine`: copiarlos obligaría a bajarlos todos, que es
    /// justamente lo que nadie espera al enchufar un disco.
    var skipUndownloadediCloud: Bool = true

    var appearance: Appearance = .system

    // MARK: Persistencia

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/backup-ssd", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Igual que en Fotosync e Itusync: cada clave se lee por separado y cae a
    /// su valor por omisión si falta.
    ///
    /// El `init(from:)` sintetizado usa `decode` y no `decodeIfPresent`, así
    /// que una sola clave ausente —añadir una opción nueva a esta struct, sin
    /// ir más lejos— haría fallar la decodificación entera. Como `load()` lo
    /// intenta con `try?`, ese fallo no se vería: la app arrancaría con la
    /// configuración de fábrica, **sin discos ni carpetas configuradas**, y
    /// parecería que se ha perdido todo.
    private enum CodingKeys: String, CodingKey {
        case volumeUUID, volumeName, rootFolder, folders, autoSyncOnMount
        case keepRemoved, removedRetentionDays, excludes, skipUndownloadediCloud, appearance
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Config()
        volumeUUID = try c.decodeIfPresent(String.self, forKey: .volumeUUID) ?? base.volumeUUID
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? base.volumeName
        rootFolder = try c.decodeIfPresent(String.self, forKey: .rootFolder) ?? base.rootFolder
        folders = try c.decodeIfPresent([SyncFolder].self, forKey: .folders) ?? base.folders
        autoSyncOnMount = try c.decodeIfPresent(Bool.self, forKey: .autoSyncOnMount) ?? base.autoSyncOnMount
        keepRemoved = try c.decodeIfPresent(Bool.self, forKey: .keepRemoved) ?? base.keepRemoved
        removedRetentionDays = try c.decodeIfPresent(Int.self, forKey: .removedRetentionDays) ?? base.removedRetentionDays
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? base.excludes
        skipUndownloadediCloud = try c.decodeIfPresent(Bool.self, forKey: .skipUndownloadediCloud) ?? base.skipUndownloadediCloud
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? base.appearance
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return cfg
    }

    /// Escribe primero a un archivo aparte y luego renombra: si el ordenador
    /// se apaga a media escritura, el archivo viejo sigue entero en vez de
    /// quedarse a medias e ilegible.
    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        let tmp = Config.fileURL.appendingPathExtension("nuevo")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? fm.replaceItemAt(Config.fileURL, withItemAt: tmp)
        } catch {
            try? data.write(to: Config.fileURL, options: .atomic)
        }
    }

    // MARK: Quién cuelga de quién

    /// La carpeta configurada de la que cuelga `folder`, si hay alguna: la
    /// más específica, por si hay varias encajadas una dentro de otra.
    ///
    /// Se miran **todas** las carpetas, incluidas las desactivadas, y a
    /// propósito. Si desactivar `Documentos/otros` la sacara de la lista, su
    /// contenido pasaría a ser contenido corriente de `Documentos`… que lo
    /// recorrería, no lo encontraría en el Mac —está en el disco, que para
    /// eso se movió— y lo retiraría entero a `_Retirados`. Desactivar una
    /// carpeta quiere decir «no la toques», nunca «trágatela desde fuera».
    func parent(of folder: SyncFolder) -> SyncFolder? {
        let mio = folder.resolvedSource
        var mejor: SyncFolder?
        for otra in folders where otra.id != folder.id {
            let suyo = otra.resolvedSource
            guard mio.hasPrefix(suyo + "/") else { continue }
            if mejor == nil || suyo.count > mejor!.resolvedSource.count { mejor = otra }
        }
        return mejor
    }

    /// Si `a` está dentro de `b` en el Mac.
    func isDescendant(_ a: SyncFolder, of b: SyncFolder) -> Bool {
        a.resolvedSource.hasPrefix(b.resolvedSource + "/")
    }

    /// Dónde acaba una carpeta dentro del disco.
    ///
    /// Si cuelga de otra configurada, ocupa **su sitio natural** dentro de
    /// aquella: `~/Documentos/otros` va a `<raíz>/Documentos/otros`, y así el
    /// disco se ve por dentro igual que el Mac. Si no cuelga de ninguna, va a
    /// `<raíz>/<nombre>` como siempre.
    ///
    /// Que el destino salga de la carpeta de fuera, y no de un ajuste aparte,
    /// es lo que hace imposible elegir dos destinos que se aniden mal: la
    /// jerarquía del disco es la del Mac porque se calcula de ella.
    func destination(of folder: SyncFolder, under root: URL) -> URL {
        guard let padre = parent(of: folder) else { return folder.destination(under: root) }
        let rel = String(folder.resolvedSource.dropFirst(padre.resolvedSource.count + 1))
        return destination(of: padre, under: root).appendingPathComponent(rel, isDirectory: true)
    }

    /// Rutas relativas que el recorrido de `folder` tiene que saltarse: las de
    /// las carpetas configuradas que cuelgan directamente de ella.
    ///
    /// Se salta **a los dos lados**, y el segundo es el que importa. En el
    /// origen, saltárselo evita copiar dos veces lo mismo. En el destino evita
    /// algo peor: `<raíz>/Documentos/otros` está lleno de lo que se movió allí
    /// y ya no está en el Mac, así que el recorrido de `Documentos` lo daría
    /// por sobrante y lo retiraría entero, deshaciendo en una pasada todo lo
    /// que el modo mover había guardado.
    func nestedRelativePaths(of folder: SyncFolder) -> Set<String> {
        var out: Set<String> = []
        let base = folder.resolvedSource
        for otra in folders where otra.id != folder.id {
            guard parent(of: otra)?.id == folder.id else { continue }
            out.insert(String(otra.resolvedSource.dropFirst(base.count + 1)))
        }
        return out
    }

    // MARK: Comprobaciones

    /// Problemas que impiden sincronizar, en el idioma de quien los va a leer.
    /// Vacío quiere decir que se puede empezar.
    func problems() -> [String] {
        var out: [String] = []
        if volumeUUID.isEmpty { out.append(L("No hay ningún disco elegido todavía.")) }
        let activas = folders.filter(\.enabled)
        if activas.isEmpty { out.append(L("No hay ninguna carpeta que copiar.")) }

        for f in activas {
            var dir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: f.source, isDirectory: &dir) {
                out.append(L("«%1$@»: la carpeta %2$@ ya no existe.", f.name, f.source))
            } else if !dir.boolValue {
                out.append(L("«%1$@»: %2$@ no es una carpeta.", f.name, f.source))
            }
            if f.name.contains("/") || f.name == ".." || f.name == "." {
                out.append(L("«%@» no vale como nombre de carpeta en el disco.", f.name))
            }
        }
        // Se compara el destino ya resuelto y no el nombre, porque con las
        // carpetas anidadas el nombre ya no manda: dos que se llamen «otros»
        // acaban en sitios distintos si cuelgan de carpetas distintas.
        //
        // Y sin distinguir mayúsculas, porque el disco puede no distinguirlas:
        // en un exFAT «Trabajo» y «trabajo» son la misma carpeta, y ahí la
        // segunda retiraría los archivos de la primera en cada pasada.
        let raiz = URL(fileURLWithPath: "/")
        var vistos: [String: SyncFolder] = [:]
        for f in activas {
            let d = destination(of: f, under: raiz).path.lowercased()
            if let otra = vistos[d] {
                out.append(L("«%1$@» y «%2$@» quieren el mismo sitio en el disco.", otra.name, f.name))
            } else {
                vistos[d] = f
            }
        }

        // Un destino dentro de otro sólo vale si viene de que una carpeta esté
        // dentro de la otra en el Mac: entonces la de fuera se salta a la de
        // dentro al recorrer. En cualquier otro caso —un `name` escrito a mano
        // en el JSON, sin ir más lejos— la de fuera recorrería el destino de
        // la de dentro, no encontraría esos archivos en su propio origen, y se
        // los llevaría a `_Retirados` en cada pasada. Sin decir nada.
        for f in activas {
            let df = destination(of: f, under: raiz).path.lowercased()
            for g in activas where g.id != f.id {
                let dg = destination(of: g, under: raiz).path.lowercased()
                guard df.hasPrefix(dg + "/"), !isDescendant(f, of: g) else { continue }
                out.append(L("El destino de «%1$@» cae dentro del de «%2$@» sin estar dentro de ella en el Mac.", f.name, g.name))
            }
        }
        return out
    }
}
