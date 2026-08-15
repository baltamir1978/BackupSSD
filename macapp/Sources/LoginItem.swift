// Arrancar al iniciar sesión.
//
// Sin esto el resto no sirve de nada: una app que sincroniza al enchufar el
// disco tiene que estar puesta cuando lo enchufas, y nadie va a acordarse de
// abrirla antes.
//
// Se usa un LaunchAgent —un archivo .plist que se puede leer, editar y borrar
// a mano— en vez de `SMAppService`, que necesita que la app esté firmada y
// notarizada para funcionar de forma fiable. Esta se compila con un script en
// casa, así que ese camino se cerraría solo.

import Foundation

enum LoginItem {
    static let label = "es.backupssd.agente"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// - Parameter appPath: dónde está el .app. Se pregunta al propio bundle,
    ///   así que funciona igual desde /Applications que desde la carpeta de
    ///   compilación mientras se prueba.
    @discardableResult
    static func set(_ enabled: Bool, appPath: String = Bundle.main.bundlePath) -> Bool {
        let fm = FileManager.default
        if !enabled {
            _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
            try? fm.removeItem(at: plistURL)
            return true
        }

        let plist: [String: Any] = [
            "Label": label,
            // `open -a` y no el ejecutable a pelo: así macOS la arranca como
            // la aplicación que es, con su icono y su bundle, y no como un
            // proceso suelto sin identidad.
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
        ]
        do {
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        // Se recarga para que valga desde ya y no sólo tras reiniciar. El
        // `bootout` previo puede fallar sin más: quiere decir que no estaba.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        return launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
