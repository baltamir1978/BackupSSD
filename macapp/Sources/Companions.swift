// Las apps que preparan carpetas para el backup: Fotosync e Itusync.
//
// Las dos hacen lo mismo con librerías distintas: sacan a carpetas normales lo
// que Fotos y Music guardan dentro de sus bibliotecas, con hard links, para
// poder verlo por álbum o por lista. Esas carpetas —«Fotos», «Musica»— son
// carpetas corrientes del Mac, así que Backup SSD las copia como cualquier
// otra… pero copia **lo que había la última vez que se exportó**. Si se han
// añadido fotos desde entonces, el backup se lleva la exportación vieja y
// nadie se entera hasta que hace falta.
//
// De ahí esto: al conectar el disco, antes de copiar, se mira si la carpeta de
// alguna de esas apps está dentro de lo que se va a copiar y si su exportación
// se ha quedado atrás. Si es así, se ejecuta la app y luego se copia.
//
// **Por qué se ejecuta la app y no la herramienta que hay debajo:** leer la
// fototeca pide Acceso completo al disco, y leer la biblioteca de Music pide el
// permiso de Multimedia. macOS concede esos permisos a una identidad de firma,
// no a una ruta: los tiene Fotosync, los tiene Itusync, y no los tiene Backup
// SSD. Lanzar `osxphotos` por nuestra cuenta no leería nada. Por eso cada app
// entiende `--export-now`, hace su trabajo sin abrir ventana y deja constancia
// en un archivo que se lee aquí.

import AppKit
import Foundation
import os

// MARK: - Quién es cada una

/// Una app compañera: la que sabe rellenar una de las carpetas del backup.
struct Companion: Identifiable, Hashable {
    /// Identificador corto y estable. Es la clave con la que se guardan sus
    /// ajustes en `DiskProfile.companions`, así que no puede cambiar aunque
    /// cambie el nombre de la app.
    let id: String
    let name: String
    let bundleID: String
    /// El binario dentro del bundle. Se ejecuta directamente y no con `open`
    /// porque hay que esperar a que termine y leer lo que dice.
    let executable: String
    /// Qué exporta, dicho para una frase: «la fototeca», «las listas de Music».
    let what: String

    /// Dónde tiene guardada su configuración. De aquí sale el destino.
    var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/\(id)/config-app.json")
    }

    /// El sello que la app deja tras cada exportación de verdad. Ver
    /// `CompanionStamp`.
    var stampURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/\(id)/last-run.json")
    }

    static let fotosync = Companion(
        id: "fotosync", name: "Fotosync", bundleID: "com.bruno.fotosync",
        executable: "Fotosync", what: L("la fototeca de Fotos"))

    static let itusync = Companion(
        id: "itusync", name: "Itusync", bundleID: "com.bruno.itusync",
        executable: "Itusync", what: L("las listas de Music"))

    static let all: [Companion] = [.fotosync, .itusync]

    static func with(id: String) -> Companion? { all.first { $0.id == id } }
}

// MARK: - Lo que dejan escrito

/// Lo que la app compañera apunta después de cada exportación real.
///
/// Es el contrato entre las tres apps, y va en un archivo suelto —no en
/// `UserDefaults`, no en un XPC— por lo mismo que la configuración de aquí: se
/// puede mirar con `cat`, sobrevive a que las apps no se hablen y no obliga a
/// que ninguna esté abierta.
struct CompanionStamp: Codable {
    var date: Date
    var destination: String
    var ok: Bool
    var summary: String

    static func read(_ c: Companion) -> CompanionStamp? {
        guard let data = try? Data(contentsOf: c.stampURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CompanionStamp.self, from: data)
    }
}

/// Sólo el destino de la configuración de la app compañera.
///
/// Se decodifica a mano y no con su struct entera a propósito: aquí no
/// interesa nada más, y así añadir una opción a Fotosync no rompe esto.
private struct CompanionConfig: Codable {
    var destination: String?
}

// MARK: - Qué se sabe de ella ahora mismo

/// La foto de una app compañera en este momento: si está, dónde exporta,
/// cuándo lo hizo por última vez y si eso cae dentro del backup de este disco.
struct CompanionState: Identifiable {
    let companion: Companion
    /// Dónde está instalada. `nil` = no está.
    var appURL: URL?
    /// El destino que tiene configurado, ya expandido. `nil` = sin configurar.
    var destination: String?
    var lastRun: Date?
    var lastOK = true
    var lastSummary = ""
    /// La carpeta del disco que contiene ese destino, si es que alguna lo
    /// contiene. Es lo que hace que esta app le importe a este disco.
    var folder: SyncFolder?

    var id: String { companion.id }
    var installed: Bool { appURL != nil }
    var inScope: Bool { folder != nil }
    /// Instalada, configurada y con su carpeta dentro del backup: sólo
    /// entonces tiene sentido ofrecer nada.
    var relevant: Bool { installed && destination != nil && inScope }

    var age: TimeInterval? { lastRun.map { Date().timeIntervalSince($0) } }

    /// Si la exportación se ha quedado vieja para la regla dada.
    ///
    /// Sin sello es que nunca se ha exportado —o que se exportó con una
    /// versión que aún no lo escribía—, y eso cuenta como vieja: más vale
    /// exportar de más una vez que copiar una carpeta a medias.
    func stale(_ rule: CompanionRule) -> Bool {
        guard let a = age else { return true }
        return a >= Double(rule.maxAgeHours) * 3600
    }

    /// «hace 3 horas», «nunca». Para la interfaz.
    var lastRunText: String {
        guard let d = lastRun else { return L("nunca") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: Detección

    /// Mira el disco y contesta. Se llama fuera del hilo principal: abre
    /// archivos y pregunta al sistema por apps instaladas.
    static func detect(_ c: Companion, disk: DiskProfile?) -> CompanionState {
        var s = CompanionState(companion: c)
        s.appURL = installedURL(c)

        if let data = try? Data(contentsOf: c.configURL),
           let cfg = try? JSONDecoder().decode(CompanionConfig.self, from: data),
           let dest = cfg.destination, !dest.isEmpty {
            s.destination = (dest as NSString).expandingTildeInPath
        }

        if let stamp = CompanionStamp.read(c) {
            // Un sello de otro destino no dice nada de éste: si alguien cambió
            // la carpeta de destino en la app, lo exportado antes está en otro
            // sitio y esta carpeta sigue sin actualizarse nunca.
            let mismo = s.destination.map {
                URL(fileURLWithPath: stamp.destination).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            } ?? false
            if mismo {
                s.lastRun = stamp.date
                s.lastOK = stamp.ok
                s.lastSummary = stamp.summary
            }
        }

        if let disk, let dest = s.destination { s.folder = folder(containing: dest, in: disk) }
        return s
    }

    static func detectAll(disk: DiskProfile?) -> [CompanionState] {
        Companion.all.map { detect($0, disk: disk) }
    }

    /// Dónde está instalada la app, si está.
    ///
    /// Se miran primero las carpetas de aplicaciones y sólo después se
    /// pregunta al sistema. Es al revés de lo que parece lógico, y a
    /// propósito: Launch Services se queda con la última copia que se abrió,
    /// que en un Mac donde se compila la app es la del directorio de
    /// compilación. Ejecutar ésa funcionaría igual, pero «instalada» quiere
    /// decir la de Aplicaciones, que es la que se actualiza y la que tiene
    /// concedidos los permisos.
    private static func installedURL(_ c: Companion) -> URL? {
        let candidatas = [
            "/Applications/\(c.name).app",
            NSHomeDirectory() + "/Applications/\(c.name).app",
        ]
        for ruta in candidatas where FileManager.default.fileExists(atPath: ruta) {
            return URL(fileURLWithPath: ruta)
        }
        // Y si no está en ninguna de las dos, donde el sistema la tenga: puede
        // estar en cualquier carpeta, y sigue siendo la app de verdad.
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundleID),
           FileManager.default.fileExists(atPath: u.path) {
            return u
        }
        return nil
    }

    /// La carpeta activa del disco dentro de la cual cae ese destino.
    ///
    /// Se comparan las rutas resueltas, igual que hace la configuración para
    /// saber quién cuelga de quién: `~/Pictures` puede ser un enlace, y sin
    /// resolverlo la carpeta de dentro no parecería estar dentro.
    ///
    /// No es privada para poder probarla: es la decisión de la que depende
    /// todo lo demás —si esta app le importa a este disco o no— y es la que
    /// más fácil se rompe con una barra de más o de menos.
    static func folder(containing path: String, in disk: DiskProfile) -> SyncFolder? {
        let dest = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var mejor: SyncFolder?
        for f in disk.folders where f.enabled {
            let raiz = f.resolvedSource
            guard dest == raiz || dest.hasPrefix(raiz + "/") else { continue }
            if mejor == nil || raiz.count > mejor!.resolvedSource.count { mejor = f }
        }
        return mejor
    }
}

// MARK: - Ajustes

/// Qué hacer con una app compañera al conectar el disco.
enum CompanionMode: String, Codable, CaseIterable {
    /// Se ejecuta sola antes de copiar, si su exportación está vieja.
    case auto
    /// No se ejecuta nada: sólo se avisa de que está vieja.
    case suggest
    /// Ni se ejecuta ni se avisa.
    case off

    var label: String {
        switch self {
        case .auto:    return L("Actualizar")
        case .suggest: return L("Avisar")
        case .off:     return L("No hacer nada")
        }
    }
}

/// La regla de una app compañera para **un** disco.
///
/// Va por disco y no por app porque las carpetas son de cada disco: el SSD
/// grande puede llevarse las fotos y el pequeño no, y en el segundo no tiene
/// ningún sentido ponerse a exportar la fototeca antes de copiar.
struct CompanionRule: Codable, Equatable {
    var mode: CompanionMode = .auto
    /// A partir de cuántas horas se considera vieja la exportación. A 0, se
    /// actualiza en cada conexión.
    var maxAgeHours: Int = 24

    /// Los intervalos que se ofrecen, en horas.
    static let intervals = [0, 6, 12, 24, 72, 168]

    static func intervalLabel(_ hours: Int) -> String {
        switch hours {
        case 0:   return L("siempre")
        case 168: return L("cada semana")
        case 24:  return L("cada día")
        // El recuento va aparte, por `plural`, y no cosido en la frase: la
        // regla del singular vive en el .stringsdict, y una clave que no
        // empiece por el marcador no llega a él.
        default:
            return hours % 24 == 0
                ? L("cada %@", plural("%ld días", hours / 24))
                : L("cada %@", plural("%ld horas", hours))
        }
    }
}

// MARK: - Ejecutarlas

/// Lo que ha pasado al ejecutar una app compañera.
struct CompanionRunResult {
    var ok: Bool
    var lines: [String] = []
    var message: String = ""
}

/// Lanza la app compañera en modo sin ventana y espera a que termine.
///
/// Se ejecuta el binario de dentro del bundle en vez de `open -a`: así se
/// espera de verdad al final del trabajo, se lee lo que va diciendo y se
/// puede parar. Y sigue siendo **la app** la que corre, con su firma y sus
/// permisos, que es de lo que depende que pueda leer la fototeca.
final class CompanionJob: Sendable {
    private struct Estado {
        var proceso: Process?
        var cancelado = false
    }
    private let estado = OSAllocatedUnfairLock(initialState: Estado())

    var isCancelled: Bool {
        estado.withLock { $0.cancelado }
    }

    func cancel() {
        let p = estado.withLock { e in
            e.cancelado = true
            return e.proceso
        }
        // `terminate` es un SIGTERM: la app compañera se entera y deja de
        // enlazar. Lo ya enlazado se queda, que es inofensivo —son hard links
        // a archivos que siguen en su sitio— y la próxima pasada lo dará por
        // hecho.
        p?.terminate()
    }

    /// Ejecuta y bloquea hasta que acabe. **No llamar desde el hilo
    /// principal.**
    func run(_ c: Companion, app: URL, onLines: @escaping @Sendable ([String]) -> Void) -> CompanionRunResult {
        let binario = app.appendingPathComponent("Contents/MacOS/\(c.executable)")
        guard FileManager.default.isExecutableFile(atPath: binario.path) else {
            return CompanionRunResult(
                ok: false,
                message: L("%1$@ está instalada pero no se pudo ejecutar: no hay binario en %2$@",
                           c.name, binario.path))
        }

        let proc = Process()
        proc.executableURL = binario
        proc.arguments = ["--export-now"]
        let tubo = Pipe()
        proc.standardOutput = tubo
        proc.standardError = tubo

        let yaParado = estado.withLock { e in
            if !e.cancelado { e.proceso = proc }
            return e.cancelado
        }
        if yaParado { return CompanionRunResult(ok: false, message: L("Detenido.")) }

        // Lo que va diciendo. Va en una clase con su cerrojo porque lo escribe
        // el hilo que lee el tubo y lo lee éste al terminar.
        let salida = LineasLeidas()
        // Se lee en otro hilo y no con `readabilityHandler`: esto ya está en
        // una cola de fondo esperando a que el proceso acabe, y así no hay que
        // montar un run loop para que lleguen los avisos.
        let lector = Thread {
            var pendiente = Data()
            while true {
                let trozo = tubo.fileHandleForReading.availableData
                if trozo.isEmpty { break }
                pendiente.append(trozo)
                while let corte = pendiente.firstIndex(of: UInt8(ascii: "\n")) {
                    let linea = String(decoding: pendiente[..<corte], as: UTF8.self)
                    pendiente.removeSubrange(...corte)
                    guard !linea.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    salida.add(linea)
                    onLines(["   " + linea])
                }
            }
        }
        lector.start()

        do { try proc.run() } catch {
            return CompanionRunResult(
                ok: false,
                message: L("No se pudo ejecutar %1$@: %2$@", c.name, error.localizedDescription))
        }
        proc.waitUntilExit()
        // Un momento para que el lector vacíe lo último que quedaba en el
        // tubo; sin esto se pierde justo el resumen final, que es la línea
        // que interesa.
        Thread.sleep(forTimeInterval: 0.15)

        let parado = estado.withLock { e in
            e.proceso = nil
            return e.cancelado
        }

        let lineas = salida.all
        if parado {
            return CompanionRunResult(ok: false, lines: lineas,
                                      message: L("%@ se detuvo a medias.", c.name))
        }
        guard proc.terminationStatus == 0 else {
            // La última línea que escribió suele ser el motivo (permiso
            // denegado, destino en otro volumen…). Decirlo tal cual ahorra
            // tener que abrir la otra app para averiguarlo.
            let motivo = lineas.last ?? L("terminó con código %ld", Int(proc.terminationStatus))
            return CompanionRunResult(ok: false, lines: lineas,
                                      message: L("%1$@ no pudo exportar: %2$@", c.name, motivo))
        }
        return CompanionRunResult(ok: true, lines: lineas, message: lineas.last ?? "")
    }
}

/// Las líneas que va escribiendo la app compañera, a salvo de que las escriba
/// un hilo y las lea otro.
private final class LineasLeidas: Sendable {
    private let lineas = OSAllocatedUnfairLock(initialState: [String]())

    func add(_ l: String) {
        lineas.withLock { $0.append(l) }
    }

    var all: [String] {
        lineas.withLock { $0 }
    }
}

// MARK: - La pasada previa a copiar

/// Ejecuta las apps compañeras que toquen antes de copiar en este disco.
///
/// Devuelve `false` si se ha parado a medias, que es lo que le dice a quien
/// llama que no siga con la copia: si alguien detiene esto, ha detenido la
/// sincronización entera, no sólo un trámite previo.
///
/// **Se llama desde una cola de fondo**, nunca desde el hilo principal: cada
/// app puede tardar minutos en recorrer su biblioteca.
func actualizarCompaneras(disk: DiskProfile,
                          job: CompanionJob,
                          onStatus: @escaping @Sendable (Companion) -> Void,
                          onLog: @escaping @Sendable ([String]) -> Void) -> Bool {
    for c in Companion.all {
        if job.isCancelled { return false }

        let regla = disk.rule(for: c)
        guard regla.mode == .auto else { continue }

        // Se vuelve a mirar aquí, y no se usa lo que la interfaz tuviera
        // guardado: entre que se enchufó el disco y que le llegó el turno, la
        // app ha podido exportar por su cuenta —o desinstalarse— y volver a
        // exportar sería tiempo tirado.
        let estado = CompanionState.detect(c, disk: disk)
        guard estado.relevant, let app = estado.appURL, let carpeta = estado.folder else { continue }
        guard estado.stale(regla) else { continue }

        onStatus(c)
        onLog([L("Actualizando «%1$@» con %2$@ antes de copiar (última vez: %3$@)…",
                 carpeta.name, c.name, estado.lastRunText)])

        let r = job.run(c, app: app, onLines: onLog)
        if job.isCancelled { return false }
        onLog(r.ok
              ? [L("%1$@ terminó: %2$@", c.name, r.message.isEmpty ? L("sin cambios") : r.message)]
              : ["⚠︎ " + r.message])
        // Que una app compañera falle no cancela la copia: lo que hay en la
        // carpeta seguirá siendo la exportación anterior, que es mejor que
        // nada y es exactamente lo que se copiaba antes de todo esto.
    }
    return !job.isCancelled
}
