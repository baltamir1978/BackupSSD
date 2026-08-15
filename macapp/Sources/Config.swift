// Configuración de Backup SSD: qué se copia, a qué disco y con qué reglas.
//
// Vive en ~/.config/backup-ssd/config.json y no en UserDefaults a propósito:
// es un archivo que se puede abrir, leer y corregir con un editor cuando algo
// va mal, y que se copia a otro Mac sin más ceremonia.

import Foundation

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
    var name: String
    var enabled: Bool = true

    init(source: String, name: String? = nil, enabled: Bool = true) {
        let path = (source as NSString).expandingTildeInPath
        self.source = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, source, name, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = ((try c.decode(String.self, forKey: .source)) as NSString).expandingTildeInPath
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (source as NSString).lastPathComponent
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// La ruta de destino de esta carpeta dentro de la raíz del backup.
    func destination(under root: URL) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
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
        // Dos carpetas con el mismo nombre se pisarían la una a la otra en el
        // destino, y la segunda «retiraría» los archivos de la primera por no
        // encontrarlos en su origen.
        let nombres = activas.map(\.name)
        for n in Set(nombres) where nombres.filter({ $0 == n }).count > 1 {
            out.append(L("Hay dos carpetas que quieren llamarse «%@» en el disco.", n))
        }
        return out
    }
}
