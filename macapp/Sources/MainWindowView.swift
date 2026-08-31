// La ventana: las carpetas que se copian, lo que está pasando ahora y lo que
// pasó las veces anteriores.
//
// Todo lo de aquí es de **un** disco: el que esté elegido arriba. Con varios
// configurados, el selector de la cabecera es lo primero que hay que mirar,
// porque las carpetas, los avisos y los botones son los suyos.

import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @ObservedObject var state: AppState
    @State private var seleccion: Set<UUID> = []
    @State private var pestana = Pestana.carpetas

    enum Pestana { case carpetas, historial, registro }

    var body: some View {
        VStack(spacing: 0) {
            if let d = state.selectedDisk {
                cabecera(d)
                avisoDeCompaneras(d)
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
                case .carpetas:  carpetas(d)
                case .historial: historial
                case .registro:  registro
                }
            } else {
                sinDiscos
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onDrop(of: [.fileURL], isTargeted: nil) { proveedores in
            guard let d = state.selectedDisk else { return false }
            recibir(proveedores, en: d.id)
            return true
        }
        // Al cambiar de disco, lo seleccionado era de las carpetas del otro.
        .onChange(of: state.selectedDisk?.id) { _ in seleccion = [] }
    }

    /// Un enlace de ida y vuelta al disco elegido, para poder editar sus
    /// carpetas con `$`.
    private func enlace(_ id: UUID) -> Binding<DiskProfile> {
        Binding(
            get: { state.config[id] ?? DiskProfile() },
            set: { state.config[id] = $0 }
        )
    }

    // MARK: Cuando todavía no hay discos

    private var sinDiscos: some View {
        VStack(spacing: 10) {
            Spacer()
            DiscoExterno(estado: .sinDisco, size: 88, animado: false)
                .padding(.bottom, 4)
            Text("Todavía no hay ningún disco configurado")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Enchufa el disco donde quieras hacer la copia y añádelo en los ajustes. Puedes tener varios, cada uno con sus carpetas.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Cabecera

    private func cabecera(_ d: DiskProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DiscoExterno(estado: EstadoDelDisco(state.status(of: d)), size: 46)
                .frame(width: 50)
                // El texto de al lado ya dice el estado; el icono repetiría.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if state.config.disks.count > 1 {
                    // Con varios discos el título no basta: hay que poder
                    // cambiar de uno a otro sin ir a los ajustes.
                    Picker("", selection: Binding(
                        get: { state.selectedDisk?.id },
                        set: { state.selectedDiskID = $0 }
                    )) {
                        ForEach(state.config.disks) { otro in
                            Text(etiqueta(otro)).tag(Optional(otro.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel(L("Disco"))
                }
                Text(titulo(d)).font(.system(.headline))
                Text(subtitulo(d)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            let estado = state.status(of: d)
            if estado.esTrabajando {
                if case .copiando(let hechos, let total, _) = estado {
                    ProgressView(value: Double(hechos), total: Double(max(total, 1)))
                        .frame(width: 150)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Detener") { state.cancel() }
                    .help("Para en cuanto acabe el archivo que tiene entre manos.")
                Button("Detener y expulsar") { state.stopAndEject(d) }
                    .disabled(state.ejecting.contains(d.id))
                    .help("Para la copia y suelta el disco para poder desconectarlo.")
            } else {
                Button("Expulsar") { state.stopAndEject(d) }
                    .disabled(!state.isConnected(d) || state.ejecting.contains(d.id))
                    .help("Suelta el disco para poder desconectarlo sin riesgo.")
                Button("Ensayo") { state.sync(d, dryRun: true) }
                    .disabled(!state.canSync(d))
                    .help("Cuenta lo que haría, sin escribir nada en el disco.")
                Button("Sincronizar ahora") { state.sync(d) }
                    .keyboardShortcut("s")
                    .disabled(!state.canSync(d))
            }
        }
        .padding(14)
    }

    // MARK: Las apps que preparan carpetas

    /// «La fototeca lleva ocho días sin exportarse».
    ///
    /// Se enseña aquí arriba y no en los ajustes porque es lo único de la app
    /// que puede hacer que el backup esté al día y aun así le falte lo de esta
    /// semana. En modo automático también se dice: mientras el disco no esté
    /// puesto, nadie va a actualizar nada, y saberlo antes de salir de casa con
    /// el disco en la mochila es justo lo que hace falta.
    @ViewBuilder
    private func avisoDeCompaneras(_ d: DiskProfile) -> some View {
        let pendientes = state.staleCompanions(of: d)
        if !pendientes.isEmpty, !state.status(of: d).esTrabajando {
            VStack(spacing: 6) {
                ForEach(pendientes) { st in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("«%1$@» se exportó por última vez %2$@.",
                                   st.folder?.name ?? st.companion.name, st.lastRunText))
                                .font(.callout)
                            Text(d.rule(for: st.companion).mode == .auto
                                 ? L("%@ la pondrá al día antes de la próxima copia.", st.companion.name)
                                 : L("Hasta que la actualices, el disco se llevará lo de entonces."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Actualizar con %@", st.companion.name)) { state.runCompanion(st) }
                            .controlSize(.small)
                            .disabled(state.status.esTrabajando)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private func etiqueta(_ d: DiskProfile) -> String {
        let nombre = d.volumeName.isEmpty ? L("Disco sin nombre") : d.volumeName
        return state.isConnected(d) ? nombre : nombre + " " + L("(no conectado)")
    }

    private func titulo(_ d: DiskProfile) -> String {
        switch state.status(of: d) {
        case .listo(let v):  return L("%@ conectado", v)
        case .actualizando(let app): return L("Actualizando con %@ antes de copiar…", app)
        case .comparando:    return L("Comparando el Mac con el disco…")
        case .copiando:      return L("Copiando…")
        case .fallo:         return L("No se pudo sincronizar")
        case .sinDisco:
            return d.volumeName.isEmpty
                ? L("Todavía no hay ningún disco elegido")
                : L("%@ no está conectado", d.volumeName)
        }
    }

    private func subtitulo(_ d: DiskProfile) -> String {
        let estado = state.status(of: d)
        if case .copiando(_, _, let actual) = estado { return actual }
        if case .actualizando(let app) = estado {
            return L("%@ está poniendo al día su carpeta; la copia empieza en cuanto termine.", app)
        }
        if case .fallo(let m) = estado { return m }
        if state.queued.contains(d.id) { return L("Esperando a que acabe el otro disco…") }
        let problemas = state.config.problems(of: d)
        if !problemas.isEmpty { return problemas.joined(separator: " · ") }
        if let u = state.lastSync(of: d) {
            return L("Última vez: %1$@ — %2$@", u.date.formatted(date: .abbreviated, time: .shortened), u.summary)
        }
        return L("Nunca se ha sincronizado.")
    }

    // MARK: Carpetas

    private func carpetas(_ d: DiskProfile) -> some View {
        let disco = enlace(d.id)
        return VStack(spacing: 0) {
            if d.folders.isEmpty {
                vacio("Arrastra aquí las carpetas que quieras copiar al disco",
                      "También puedes añadirlas con el botón +")
            } else {
                List(selection: $seleccion) {
                    ForEach(disco.folders) { $f in
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
                                Text(L("En el disco: %@", destinoDe(f, en: d)))
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
                    Button { anadir(a: d.id) } label: { Image(systemName: "plus") }
                        .help("Añadir una carpeta")
                        .accessibilityLabel("Añadir una carpeta")
                    Button {
                        state.removeFolders(seleccion, from: d.id); seleccion = []
                    } label: { Image(systemName: "minus") }
                        .disabled(seleccion.isEmpty)
                        .help("Quitar la carpeta de la lista. No borra nada del disco.")
                        .accessibilityLabel("Quitar la carpeta de la lista. No borra nada del disco.")
                    Spacer()
                    Text(resumenDeCarpetas(d)).font(.caption).foregroundStyle(.secondary)
                }
                // El modo mover es lo único de este programa que borra algo del
                // Mac. Se dice aquí, siempre a la vista mientras esté activo, y
                // no sólo en la ayudita del menú que hay que ir a buscar.
                let seVacian = d.folders.filter { $0.enabled && $0.mode == .move }.count
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

    private func resumenDeCarpetas(_ d: DiskProfile) -> String {
        let activas = d.folders.filter(\.enabled).count
        let total = d.folders.count
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
                    // Perezosa: el detalle de una copia entera son miles de
                    // líneas, y un VStack normal las construye todas de golpe
                    // aunque no se vea ninguna.
                    LazyVStack(alignment: .leading, spacing: 3) {
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
    /// backup. Se calcula igual que en el motor, pasando por la configuración
    /// del disco, para que lo que se enseña aquí no pueda separarse de lo que
    /// se hace.
    private func destinoDe(_ f: SyncFolder, en d: DiskProfile) -> String {
        let raiz = d.rootFolder.trimmingCharacters(in: .whitespaces)
        let bajo = URL(fileURLWithPath: "/" + (raiz.isEmpty ? "Backup-SSD" : raiz))
        return String(d.destination(of: f, under: bajo).path.dropFirst())
    }

    private func anadir(a id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir"
        panel.message = "Elige las carpetas del Mac que quieres copiar al disco."
        if panel.runModal() == .OK {
            for url in panel.urls { state.addFolder(url, to: id) }
        }
    }

    private func recibir(_ proveedores: [NSItemProvider], en id: UUID) {
        for p in proveedores {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var esDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &esDir),
                      esDir.boolValue else { return }
                DispatchQueue.main.async { state.addFolder(url, to: id) }
            }
        }
    }
}
