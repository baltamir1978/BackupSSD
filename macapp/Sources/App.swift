// El punto de entrada y las tres escenas: el menú de la barra, la ventana y
// los ajustes.

import SwiftUI

@main
struct BackupSSDApp: App {
    @StateObject private var state = AppState()
    /// `NSApp.setActivationPolicy` en el arranque: la app vive en la barra de
    /// menús y no debe ocupar sitio en el Dock mientras no haya ventana.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            IconoDeLaBarra(state: state)
        }
        .menuBarExtraStyle(.window)

        Window("Backup SSD", id: "principal") {
            MainWindowView(state: state)
                .preferredColorScheme(state.config.appearance.colorScheme)
        }
        .defaultSize(width: 720, height: 520)
        .commands { CommandGroup(replacing: .newItem) {} }

        // Una ventana corriente y no la escena `Settings`.
        //
        // `Settings` sólo se puede abrir desde código llamando a un selector
        // que Apple no documenta y que además cambió de nombre en macOS 14
        // (`showPreferencesWindow:` → `showSettingsWindow:`). En macOS 26 no
        // respondía ninguno de los dos: pulsabas «Ajustes…» y no pasaba
        // absolutamente nada. Una ventana con su identificador se abre con
        // `openWindow`, que es API pública y funciona igual en toda versión.
        Window("Ajustes de Backup SSD", id: "ajustes") {
            SettingsView(state: state)
                .preferredColorScheme(state.config.appearance.colorScheme)
        }
        .defaultSize(width: 500, height: 430)
        .windowResizability(.contentSize)
    }
}

/// El icono de la barra de menús, que cambia con el estado: es el único sitio
/// donde se ve que está copiando sin abrir nada.
///
/// Es una vista aparte y no un `Image` suelto porque necesita `openWindow`, y
/// eso sólo se puede pedir desde dentro de una vista.
private struct IconoDeLaBarra: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.menuIcon)
            .accessibilityLabel(L("Backup SSD"))
            .accessibilityValue(state.accessibilityStatus)
            .onAppear {
                // Recién instalada no hay disco ni carpetas, y la app se
                // quedaría en la barra sin hacer nada y sin decir por dónde
                // empezar. Se abren los ajustes solos la primera vez —y
                // mientras siga sin configurar, que es cuando hace falta.
                guard state.config.volumeUUID.isEmpty, state.config.folders.isEmpty else { return }
                WindowOpener.activate()
                openWindow(id: "ajustes")
                WindowOpener.bringToFront(titled: L("Ajustes de Backup SSD"))
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // Sin esto la app aparecería en el Dock y en el conmutador de
        // aplicaciones, que para algo que vive en la barra de menús sobra.
        // Las ventanas siguen abriéndose igual.
        NSApp.setActivationPolicy(.accessory)

        // Al cerrar la última ventana hay que volver a esconderse. Abrirla
        // obliga a pasar a `.regular` —si no, se abre detrás de todo— y sin
        // esto la app se quedaría en el Dock el resto de la sesión, que es
        // justo lo que no queremos de algo que vive en la barra de menús.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                let quedan = NSApp.windows.contains {
                    $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
                }
                if !quedan { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// La app no se cierra al cerrar su ventana: sigue esperando al disco.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Al pulsar el icono en el Dock —cuando hay ventana abierta y la política
    /// ha vuelto a `.regular`— se trae al frente lo que haya.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

extension AppState {
    /// El estado dicho con palabras, para quien no ve el icono.
    var accessibilityStatus: String {
        switch status {
        case .sinDisco:
            return config.volumeName.isEmpty
                ? L("Sin disco elegido")
                : L("%@ no está conectado", config.volumeName)
        case .listo(let v):  return L("%@ conectado", v)
        case .comparando:    return L("Comparando…")
        case .copiando(let hechos, let total, _):
            return L("Copiando…") + " " + L("%1$@ de %2$@", "\(hechos)", "\(total)")
        case .fallo(let m):  return m
        }
    }

    var menuIcon: String {
        switch status {
        case .copiando, .comparando: return "arrow.triangle.2.circlepath"
        case .fallo:                 return "externaldrive.badge.exclamationmark"
        case .listo:                 return "externaldrive.fill.badge.checkmark"
        case .sinDisco:              return "externaldrive"
        }
    }
}

// MARK: - Abrir ventanas desde el menú

/// Hace falta el paso por `NSApp`: una app con política `.accessory` puede
/// abrir ventanas, pero se quedan detrás de lo que hubiera delante, y quien
/// pulsa «Ajustes» se queda mirando la pantalla sin ver nada.
enum WindowOpener {
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Trae al frente la ventana que se acaba de pedir.
    ///
    /// Va un ciclo por detrás a propósito: `openWindow` no la ha creado
    /// todavía cuando vuelve, así que pedirla al frente en el mismo momento no
    /// serviría de nada.
    static func bringToFront(titled titulo: String) {
        DispatchQueue.main.async {
            let v = NSApp.windows.first { $0.title == titulo } ?? NSApp.windows.first { $0.isVisible }
            v?.makeKeyAndOrderFront(nil)
        }
    }
}
