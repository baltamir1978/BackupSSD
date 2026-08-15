// El menú de la barra: lo que se ve al pulsar el icono.
//
// Tiene que responder de un vistazo a «¿está el disco?» y «¿está al día?».
// Todo lo demás cabe en la ventana.

import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    /// Cierra el panel del menú. En el estilo `.window` no se cierra solo al
    /// pulsar algo dentro —no es un menú de verdad, es una ventanita—, así que
    /// sin esto se queda colgado delante de lo que acabas de abrir.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            estado

            if state.status.esTrabajando {
                progreso
            } else if let ultima = state.lastSync {
                Divider()
                ultimaVez(ultima)
            }

            Divider()
            botones
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Partes

    private var estado: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colorDelEstado)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tituloDelEstado).font(.system(.body, weight: .semibold))
                if let sub = subtituloDelEstado {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var progreso: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .copiando(let hechos, let total, let actual) = state.status {
                ProgressView(value: Double(hechos), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(L("Copiando…"))
                    .accessibilityValue(L("%1$@ de %2$@", "\(hechos)", "\(total)"))
                Text(actual)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L("%1$@ de %2$@", "\(hechos)", "\(total)"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Button("Cancelar") { state.cancel() }
                .controlSize(.small)
        }
    }

    private func ultimaVez(_ e: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Última: %@", e.date.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(e.summary)
                .font(.callout)
                .foregroundStyle(e.ok ? .primary : .secondary)
                .lineLimit(2)
        }
    }

    private var botones: some View {
        VStack(alignment: .leading, spacing: 2) {
            FilaDeMenu(L("Sincronizar ahora"), key: "s", enabled: state.canSync) {
                dismiss()
                state.sync()
            }
            FilaDeMenu(L("Abrir el disco"), enabled: state.volume != nil) {
                dismiss()
                if let v = state.volume { NSWorkspace.shared.open(v.url) }
            }
            // El texto cambia porque la acción cambia: si está copiando, esto
            // primero para y luego expulsa, y conviene decirlo antes de
            // pulsarlo.
            FilaDeMenu(state.status.esTrabajando ? L("Detener y expulsar el disco") : L("Expulsar el disco"),
                       enabled: state.volume != nil && !state.ejecting) {
                dismiss()
                state.stopAndEject()
            }
            Divider().padding(.vertical, 3)
            FilaDeMenu(L("Ventana de Backup SSD…")) { abrir("principal", titulo: "Backup SSD") }
            FilaDeMenu(L("Ajustes…"), key: ",") { abrir("ajustes", titulo: L("Ajustes de Backup SSD")) }
            Divider().padding(.vertical, 3)
            FilaDeMenu(L("Salir de Backup SSD"), key: "q") { NSApp.terminate(nil) }
        }
    }

    /// Cerrar el panel, sacar la app de la barra de menús y abrir la ventana,
    /// en ese orden. Cambiar el orden se nota: la ventana aparece detrás.
    private func abrir(_ id: String, titulo: String) {
        dismiss()
        WindowOpener.activate()
        openWindow(id: id)
        WindowOpener.bringToFront(titled: titulo)
    }

    // MARK: Cómo se dice el estado

    private var tituloDelEstado: String {
        switch state.status {
        case .sinDisco:
            return state.config.volumeName.isEmpty
                ? L("Sin disco elegido")
                : L("%@ no está conectado", state.config.volumeName)
        case .listo(let v):   return L("%@ conectado", v)
        case .comparando:     return L("Comparando…")
        case .copiando:       return L("Copiando…")
        case .fallo:          return L("No se pudo sincronizar")
        }
    }

    private var subtituloDelEstado: String? {
        switch state.status {
        case .sinDisco:
            return state.config.volumeName.isEmpty
                ? L("Elige el disco en los ajustes")
                : L("Se sincronizará al conectarlo")
        case .listo:
            let problemas = state.config.problems()
            if !problemas.isEmpty { return problemas.first }
            return state.config.autoSyncOnMount ? L("Se sincroniza solo al conectarlo") : nil
        case .fallo(let m): return m
        default: return nil
        }
    }

    private var colorDelEstado: Color {
        switch state.status {
        case .listo:                 return .green
        case .comparando, .copiando: return .blue
        case .fallo:                 return .red
        case .sinDisco:              return .secondary
        }
    }
}

/// Una línea de menú de las de toda la vida: ocupa el ancho entero y se
/// ilumina al pasar por encima. `MenuBarExtra` en modo ventana no da menús de
/// verdad, así que se imita el comportamiento que la gente espera.
private struct FilaDeMenu: View {
    let titulo: String
    var key: String? = nil
    var enabled = true
    let accion: () -> Void

    @State private var encima = false

    init(_ titulo: String, key: String? = nil, enabled: Bool = true, accion: @escaping () -> Void) {
        self.titulo = titulo
        self.key = key
        self.enabled = enabled
        self.accion = accion
    }

    var body: some View {
        Button(action: accion) {
            HStack {
                Text(titulo)
                Spacer()
                if let k = key {
                    Text(verbatim: "⌘\(k.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(encima && enabled ? Color.accentColor.opacity(0.9) : .clear)
            )
            .foregroundStyle(encima && enabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        // El contenido es un HStack, así que sin esto el botón no tiene
        // nombre: VoiceOver leería «botón» a secas cinco veces seguidas.
        .accessibilityLabel(titulo)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { encima = $0 }
        .modifier(AtajoOpcional(key: key))
    }
}

private struct AtajoOpcional: ViewModifier {
    let key: String?
    func body(content: Content) -> some View {
        if let k = key, let c = k.first {
            content.keyboardShortcut(KeyEquivalent(c), modifiers: .command)
        } else {
            content
        }
    }
}
