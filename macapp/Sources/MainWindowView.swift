// La ventana: las carpetas que se copian, lo que está pasando ahora y lo que
// pasó las veces anteriores.

import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @ObservedObject var state: AppState
    @State private var seleccion: Set<UUID> = []
    @State private var pestana = Pestana.carpetas

    enum Pestana { case carpetas, historial, registro }

    var body: some View {
        VStack(spacing: 0) {
            cabecera
            Divider()
            Picker("", selection: $pestana) {
                Text("Carpetas").tag(Pestana.carpetas)
                Text("Historial").tag(Pestana.historial)
                Text("Registro").tag(Pestana.registro)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            switch pestana {
            case .carpetas:  carpetas
            case .historial: historial
            case .registro:  registro
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onDrop(of: [.fileURL], isTargeted: nil) { proveedores in
            recibir(proveedores)
            return true
        }
    }

    // MARK: Cabecera

    private var cabecera: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.menuIcon)
                .font(.system(.largeTitle))
                .foregroundStyle(state.volume != nil ? Color.accentColor : .secondary)
                .frame(width: 34)
                // El texto de al lado ya dice el estado; el icono repetiría.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(.system(.headline))
                Text(subtitulo).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            if state.status.esTrabajando {
                if case .copiando(let hechos, let total, _) = state.status {
                    ProgressView(value: Double(hechos), total: Double(max(total, 1)))
                        .frame(width: 150)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Detener") { state.cancel() }
                    .help("Para en cuanto acabe el archivo que tiene entre manos.")
                Button("Detener y expulsar") { state.stopAndEject() }
                    .disabled(state.ejecting)
                    .help("Para la copia y suelta el disco para poder desconectarlo.")
            } else {
                Button("Expulsar") { state.stopAndEject() }
                    .disabled(state.volume == nil || state.ejecting)
                    .help("Suelta el disco para poder desconectarlo sin riesgo.")
                Button("Ensayo") { state.sync(dryRun: true) }
                    .disabled(!state.canSync)
                    .help("Cuenta lo que haría, sin escribir nada en el disco.")
                Button("Sincronizar ahora") { state.sync() }
                    .keyboardShortcut("s")
                    .disabled(!state.canSync)
            }
        }
        .padding(14)
    }

    private var titulo: String {
        switch state.status {
        case .listo(let v):  return L("%@ conectado", v)
        case .comparando:    return L("Comparando el Mac con el disco…")
        case .copiando:      return L("Copiando…")
        case .fallo:         return L("No se pudo sincronizar")
        case .sinDisco:
            return state.config.volumeName.isEmpty
                ? L("Todavía no hay ningún disco elegido")
                : L("%@ no está conectado", state.config.volumeName)
        }
    }

    private var subtitulo: String {
        if case .copiando(_, _, let actual) = state.status { return actual }
        if case .fallo(let m) = state.status { return m }
        let problemas = state.config.problems()
        if !problemas.isEmpty { return problemas.joined(separator: " · ") }
        if let u = state.lastSync {
            return L("Última vez: %1$@ — %2$@", u.date.formatted(date: .abbreviated, time: .shortened), u.summary)
        }
        return L("Nunca se ha sincronizado.")
    }

    // MARK: Carpetas

    private var carpetas: some View {
        VStack(spacing: 0) {
            if state.config.folders.isEmpty {
                vacio("Arrastra aquí las carpetas que quieras copiar al disco",
                      "También puedes añadirlas con el botón +")
            } else {
                List(selection: $seleccion) {
                    ForEach($state.config.folders) { $f in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $f.enabled)
                                .labelsHidden()
                                .accessibilityLabel(f.name)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(.body, weight: .medium))
                                Text(acortar(f.source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // A dónde va dentro del disco. Con las carpetas
                                // anidadas ya no se puede adivinar mirando el
                                // nombre, y en modo mover conviene verlo bien
                                // claro antes de que se vacíe nada.
                                Text(L("En el disco: %@", destinoDe(f)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if !FileManager.default.fileExists(atPath: f.source) {
                                Label("no está", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .labelStyle(.titleAndIcon)
                            }
                            Picker("", selection: $f.mode) {
                                ForEach(FolderMode.allCases, id: \.self) { m in
                                    Text(m.label).tag(m)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityLabel(L("Qué hacer con «%@»", f.name))
                            .help(f.mode.explanation)
                        }
                        .opacity(f.enabled ? 1 : 0.45)
                        .padding(.vertical, 2)
                        .tag(f.id)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { anadir() } label: { Image(systemName: "plus") }
                        .help("Añadir una carpeta")
                        .accessibilityLabel("Añadir una carpeta")
                    Button { state.removeFolders(seleccion); seleccion = [] } label: { Image(systemName: "minus") }
                        .disabled(seleccion.isEmpty)
                        .help("Quitar la carpeta de la lista. No borra nada del disco.")
                        .accessibilityLabel("Quitar la carpeta de la lista. No borra nada del disco.")
                    Spacer()
                    Text(resumenDeCarpetas).font(.caption).foregroundStyle(.secondary)
                }
                // El modo mover es lo único de este programa que borra algo del
                // Mac. Se dice aquí, siempre a la vista mientras esté activo, y
                // no sólo en la ayudita del menú que hay que ir a buscar.
                if seVacian > 0 {
                    Label(L("%@ se vacían al disco: lo que hay dentro se copia y se borra del Mac.",
                            plural("%ld carpetas", seVacian)),
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
        }
    }

    /// Cuántas carpetas activas se llevan su contenido al disco.
    private var seVacian: Int {
        state.config.folders.filter { $0.enabled && $0.mode == .move }.count
    }

    private var resumenDeCarpetas: String {
        let activas = state.config.folders.filter(\.enabled).count
        let total = state.config.folders.count
        if total == 0 { return "" }
        return activas == total ? plural("%ld carpetas", total) : L("%1$@ de %2$@ activas", "\(activas)", "\(total)")
    }

    // MARK: Historial

    private var historial: some View {
        Group {
            if state.history.isEmpty {
                vacio("Aquí saldrá lo que se copie", "Todavía no hay ninguna sincronización.")
            } else {
                List {
                    ForEach(state.history) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: e.failure != nil ? "xmark.circle.fill"
                                  : e.cancelled ? "stop.circle.fill"
                                  : e.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(e.failure != nil ? .red
                                                 : e.cancelled ? .secondary
                                                 : e.errors.isEmpty ? .green : .orange)
                                .accessibilityLabel(e.failure != nil ? L("No se pudo sincronizar")
                                                    : e.cancelled ? L("Detener")
                                                    : e.errors.isEmpty ? L("sin cambios") : plural("%ld con error", e.errors.count))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.summary).font(.callout)
                                HStack(spacing: 6) {
                                    Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                    if e.bytes > 0 { Text(verbatim: "· \(fmtBytes(e.bytes))") }
                                    if e.duration > 1 { Text(verbatim: "· \(Int(e.duration)) s") }
                                    if !e.volumeName.isEmpty { Text(verbatim: "· \(e.volumeName)") }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button("Vaciar el historial") { state.clearHistory() }
                            .controlSize(.small)
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: Registro

    private var registro: some View {
        Group {
            if state.log.isEmpty {
                vacio("Sin novedades", "Aquí aparecen los avisos de la última sincronización.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(state.log.enumerated()), id: \.offset) { _, linea in
                            Text(linea)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    // MARK: Auxiliares

    private func vacio(_ titulo: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Text(titulo).font(.system(.body, weight: .medium)).foregroundStyle(.secondary)
            Text(sub).font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func acortar(_ ruta: String) -> String {
        let casa = NSHomeDirectory()
        return ruta.hasPrefix(casa) ? "~" + ruta.dropFirst(casa.count) : ruta
    }

    /// Dónde acaba esta carpeta dentro del disco, contando desde la raíz del
    /// backup. Se calcula igual que en el motor, pasando por la configuración,
    /// para que lo que se enseña aquí no pueda separarse de lo que se hace.
    private func destinoDe(_ f: SyncFolder) -> String {
        let raiz = state.config.rootFolder.trimmingCharacters(in: .whitespaces)
        let bajo = URL(fileURLWithPath: "/" + (raiz.isEmpty ? "Backup-SSD" : raiz))
        return String(state.config.destination(of: f, under: bajo).path.dropFirst())
    }

    private func anadir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir"
        panel.message = "Elige las carpetas del Mac que quieres copiar al disco."
        if panel.runModal() == .OK {
            for url in panel.urls { state.addFolder(url) }
        }
    }

    private func recibir(_ proveedores: [NSItemProvider]) {
        for p in proveedores {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var esDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &esDir),
                      esDir.boolValue else { return }
                DispatchQueue.main.async { state.addFolder(url) }
            }
        }
    }
}
