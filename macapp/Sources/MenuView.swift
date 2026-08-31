// El menú de la barra: lo que se ve al pulsar el icono.
//
// Tiene que responder de un vistazo a «¿está el disco?» y «¿está al día?».
// Todo lo demás cabe en la ventana.
//
// Con un solo disco configurado es exactamente el menú de siempre. En cuanto
// hay más, cada disco trae su propio bloque: nunca hay un «Sincronizar ahora» a
// secas del que haya que adivinar a cuál se refiere.

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
            // Los que esperan turno se dicen aquí: si no, un disco enchufado y
            // quieto parecería olvidado.
            ForEach(state.queued, id: \.self) { id in
                if let d = state.config[id] {
                    Text(L("En espera: %@", d.volumeName.isEmpty ? L("Disco sin nombre") : d.volumeName))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
            if state.config.disks.count > 1 {
                variosDiscos
            } else {
                unDisco
            }
            Divider().padding(.vertical, 3)
            FilaDeMenu(L("Ventana de Backup SSD…")) { abrir("principal", titulo: "Backup SSD") }
            FilaDeMenu(L("Ajustes…"), key: ",") { abrir("ajustes", titulo: L("Ajustes de Backup SSD")) }
            Divider().padding(.vertical, 3)
            FilaDeMenu(L("Salir de Backup SSD"), key: "q") { NSApp.terminate(nil) }
        }
    }

    /// El menú de toda la vida, cuando sólo hay un disco (o ninguno).
    @ViewBuilder
    private var unDisco: some View {
        let d = state.config.disks.first
        FilaDeMenu(L("Sincronizar ahora"), key: "s", enabled: d.map { state.canSync($0) } ?? false) {
            dismiss()
            if let d { state.sync(d) }
        }
        FilaDeMenu(L("Abrir el disco"), enabled: conectado(d) != nil) {
            dismiss()
            if let v = conectado(d) { NSWorkspace.shared.open(v.url) }
        }
        // El texto cambia porque la acción cambia: si está copiando, esto
        // primero para y luego expulsa, y conviene decirlo antes de pulsarlo.
        FilaDeMenu(state.status.esTrabajando ? L("Detener y expulsar el disco") : L("Expulsar el disco"),
                   enabled: conectado(d) != nil && !(d.map { state.ejecting.contains($0.id) } ?? true)) {
            dismiss()
            if let d { state.stopAndEject(d) }
        }
    }

    /// Con varios discos, cada uno con lo suyo y su nombre por delante.
    @ViewBuilder
    private var variosDiscos: some View {
        let listos = state.config.disks.filter { state.canSync($0) }
        if listos.count > 1 {
            FilaDeMenu(L("Sincronizar los %@ discos", "\(listos.count)"), key: "s") {
                dismiss()
                state.syncAll()
            }
            Divider().padding(.vertical, 3)
        }

        ForEach(state.config.disks) { d in
            Text(d.volumeName.isEmpty ? L("Disco sin nombre") : d.volumeName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            Text(pieDe(d))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            if state.isConnected(d) {
                FilaDeMenu(L("Sincronizar ahora"), enabled: state.canSync(d)) {
                    dismiss()
                    state.sync(d)
                }
                FilaDeMenu(L("Abrir el disco")) {
                    dismiss()
                    if let v = state.volume(of: d) { NSWorkspace.shared.open(v.url) }
                }
                FilaDeMenu(state.working == d.id ? L("Detener y expulsar el disco") : L("Expulsar el disco"),
                           enabled: !state.ejecting.contains(d.id)) {
                    dismiss()
                    state.stopAndEject(d)
                }
            }
        }
    }

    /// En dos palabras, qué le pasa a este disco: es lo que sustituye al
    /// «Sincronizar ahora» a secas cuando hay más de uno.
    private func pieDe(_ d: DiskProfile) -> String {
        if case .actualizando(let app) = state.status(of: d) { return L("Actualizando con %@…", app) }
        if state.working == d.id { return L("Copiando…") }
        if state.queued.contains(d.id) { return L("En espera") }
        switch state.status(of: d) {
        case .fallo(let m): return m
        case .sinDisco:     return L("no conectado")
        default:
            let problemas = state.config.problems(of: d)
            if let p = problemas.first { return p }
            return d.autoSyncOnMount ? L("Se sincroniza solo al conectarlo") : L("conectado")
        }
    }

    private func conectado(_ d: DiskProfile?) -> VolumeInfo? {
        guard let d else { return nil }
        return state.volume(of: d)
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

    /// El disco del que habla la cabecera: el que está copiando, o el primero
    /// que esté puesto, o el primero que haya.
    private var enPantalla: DiskProfile? {
        if let w = state.working, let d = state.config[w] { return d }
        return state.config.disks.first { state.isConnected($0) } ?? state.config.disks.first
    }

    private var tituloDelEstado: String {
        switch state.status {
        case .sinDisco:
            guard let d = enPantalla, !d.volumeName.isEmpty else { return L("Sin disco elegido") }
            return L("%@ no está conectado", d.volumeName)
        case .listo(let v):   return L("%@ conectado", v)
        case .actualizando(let app): return L("Actualizando con %@…", app)
        case .comparando:     return L("Comparando…")
        case .copiando:
            guard let d = enPantalla, !d.volumeName.isEmpty else { return L("Copiando…") }
            return L("Copiando en %@…", d.volumeName)
        case .fallo:          return L("No se pudo sincronizar")
        }
    }

    private var subtituloDelEstado: String? {
        switch state.status {
        case .sinDisco:
            return enPantalla == nil
                ? L("Elige el disco en los ajustes")
                : L("Se sincronizará al conectarlo")
        case .listo:
            guard let d = enPantalla else { return nil }
            let problemas = state.config.problems(of: d)
            if !problemas.isEmpty { return problemas.first }
            return d.autoSyncOnMount ? L("Se sincroniza solo al conectarlo") : nil
        case .actualizando:
            return L("Antes de copiar, para que el disco se lleve lo de hoy.")
        case .fallo(let m): return m
        default: return nil
        }
    }

    private var colorDelEstado: Color {
        switch state.status {
        case .listo:                 return .green
        case .actualizando, .comparando, .copiando: return .blue
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
