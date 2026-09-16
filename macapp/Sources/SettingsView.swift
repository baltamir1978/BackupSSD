// Los ajustes. El de arriba —qué discos— es el que importa; el resto son
// matices que casi nadie tocará.
//
// Todo lo de «Copia» y «Excluir» es de un disco en concreto, no de la app: por
// eso las tres pestañas miran al mismo disco elegido, y por eso el nombre de
// ese disco se ve siempre. Cambiarle las carpetas al disco que no era, creyendo
// que se le cambian a otro, es de los errores que no se notan hasta que ya se
// ha copiado.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    /// Fijada a mano, y no dejando que el `TabView` elija: sin selección
    /// explícita se abría por «Copia», y lo primero que hay que hacer aquí
    /// —elegir el disco— quedaba en una pestaña que nadie había pulsado.
    @State private var pestana = Pestana.disco

    private enum Pestana: Hashable { case disco, copia, apps, excluir, general }

    var body: some View {
        TabView(selection: $pestana) {
            DiscosTab(state: state)
                .tabItem { Label("Discos", systemImage: "externaldrive") }
                .tag(Pestana.disco)
            CopiaTab(state: state)
                .tabItem { Label("Copia", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Pestana.copia)
            CompanerasTab(state: state)
                .tabItem { Label("Apps", systemImage: "clock.arrow.circlepath") }
                .tag(Pestana.apps)
            ExclusionesTab(state: state)
                .tabItem { Label("Excluir", systemImage: "nosign") }
                .tag(Pestana.excluir)
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pestana.general)
        }
        // El ancho lo manda la barra de pestañas, no el contenido: si los cinco
        // títulos no caben de una vez, macOS esconde los que sobran detrás de
        // un desplegable con flechas —y enseña ahí su nombre interno, «Navigation
        // Tab Bar»—, que es de lo peor que puede pasarle a una ventana de
        // ajustes. Al añadir o renombrar una pestaña hay que comprobar que
        // siguen cabiendo las cinco.
        .frame(width: 580, height: 470)
    }
}

// MARK: - Piezas compartidas

/// El disco al que se le están cambiando las cosas.
///
/// Se enseña siempre, incluso con un solo disco configurado: es la respuesta a
/// «¿a cuál de ellos le estoy tocando esto?», y no tenerla a la vista es lo que
/// convierte un ajuste en una sorpresa.
private struct CabeceraDeDisco: View {
    @ObservedObject var state: AppState

    var body: some View {
        if state.config.disks.count > 1 {
            Picker("Ajustes de", selection: Binding(
                get: { state.selectedDisk?.id },
                set: { state.selectedDiskID = $0 }
            )) {
                ForEach(state.config.disks) { d in
                    Text(nombre(d)).tag(Optional(d.id))
                }
            }
        } else if let d = state.selectedDisk {
            LabeledContent("Ajustes de") { Text(nombre(d)) }
        }
    }

    private func nombre(_ d: DiskProfile) -> String {
        d.volumeName.isEmpty ? L("Disco sin nombre") : d.volumeName
    }
}

/// Lo que se enseña en «Copia» y «Excluir» cuando todavía no hay ningún disco.
private struct SinDiscos: View {
    var body: some View {
        VStack(spacing: 8) {
            DiscoExterno(estado: .sinDisco, size: 64, animado: false)
                .padding(.bottom, 4)
            Text("Añade un disco en la pestaña «Discos».")
                .foregroundStyle(.secondary)
            Text("Cada disco lleva sus propias carpetas y sus propios ajustes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Un enlace de ida y vuelta al disco elegido, para poder editarlo con `$`.
@MainActor
private func enlace(_ state: AppState, _ id: UUID) -> Binding<DiskProfile> {
    Binding(
        get: { state.config[id] ?? DiskProfile() },
        set: { state.config[id] = $0 }
    )
}

// MARK: - Discos

private struct DiscosTab: View {
    @ObservedObject var state: AppState

    /// Conectados y todavía sin configurar. Los externos primero: son los que
    /// alguien querría de destino. Las demás particiones internas se enseñan
    /// también, por si la copia va a otra de ellas.
    ///
    /// El disco de arranque no sale nunca. Copiar el Mac dentro del propio Mac
    /// no es una copia de seguridad —un fallo del disco se lleva las dos a la
    /// vez—, y ofrecerlo aquí sólo servía para poder elegirlo por error.
    private var porAnadir: [VolumeInfo] {
        let ya = Set(state.config.disks.map(\.volumeUUID))
        let libres = state.volumes.filter { !ya.contains($0.uuid) && !$0.isBoot }
        return libres.filter(\.looksLikeBackupDisk) + libres.filter { !$0.looksLikeBackupDisk }
    }

    var body: some View {
        Form {
            Section {
                if state.config.disks.isEmpty {
                    Text("Todavía no hay ningún disco configurado")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.config.disks) { d in
                        FilaDeDisco(state: state, disk: d)
                    }
                }
            } header: {
                Text("Tus discos")
            } footer: {
                Text("Cada disco guarda sus propias carpetas y sus propios ajustes. Se recuerdan por su identificador, no por su nombre: dos discos pueden llamarse igual y copiar en el que no es sería un desastre.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if porAnadir.isEmpty {
                    Text(state.volumes.isEmpty
                         ? "No hay ningún disco externo conectado."
                         : "Todos los discos conectados están ya configurados.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(porAnadir) { v in
                        HStack(spacing: 10) {
                            if v.isInternal {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30)
                            } else {
                                // Sin luz de estado: todavía no es un disco de
                                // la casa, sólo uno que está enchufado.
                                DiscoExterno(estado: .sinDisco, size: 30, animado: false)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name)
                                Text(v.uuid)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Añadir") { state.addDisk(v) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Conectados ahora")
            }

            if let d = state.selectedDisk {
                Section {
                    TextField("Carpeta dentro del disco", text: enlace(state, d.id).rootFolder)
                } header: {
                    CabeceraDeDisco(state: state)
                } footer: {
                    Text("Todo cuelga de esta carpeta, para que el disco pueda tener además otras cosas que Backup SSD no toca nunca.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // La lista se mantiene sola: `AppState` la rehace en cuanto se monta o
        // se quita cualquier disco. Aquí sólo se pide una vez al abrir, por si
        // algo cambió mientras la ventana estaba cerrada.
        .onAppear { state.reloadVolumes() }
    }
}

private struct FilaDeDisco: View {
    @ObservedObject var state: AppState
    let disk: DiskProfile
    @State private var preguntando = false

    private var elegido: Bool { state.selectedDisk?.id == disk.id }

    var body: some View {
        HStack(spacing: 10) {
            DiscoExterno(estado: EstadoDelDisco(state.status(of: disk)), size: 30, animado: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(disk.volumeName.isEmpty ? L("Disco sin nombre") : disk.volumeName)
                    .fontWeight(elegido ? .semibold : .regular)
                Text(subtitulo)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isConnected(disk) {
                Text("Conectado")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button {
                preguntando = true
            } label: {
                Image(systemName: "minus")
            }
            .controlSize(.small)
            .help(L("Quitar este disco de la configuración"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { state.selectedDiskID = disk.id }
        // Quitar un disco tira su configuración entera, y con varios discos es
        // fácil pulsar el «−» de la fila de al lado. Lo que hay en el disco no
        // se toca, y conviene decirlo aquí para que nadie lo dude.
        .confirmationDialog(L("¿Quitar «%@» de Backup SSD?", disk.volumeName),
                            isPresented: $preguntando, titleVisibility: .visible) {
            Button(L("Quitar"), role: .destructive) { state.removeDisk(disk.id) }
            Button(L("Cancelar"), role: .cancel) {}
        } message: {
            Text("Se olvidan sus carpetas y sus ajustes. Lo que ya está copiado en el disco no se toca.")
        }
    }

    private var subtitulo: String {
        let carpetas = disk.folders.filter(\.enabled).count
        return carpetas == 0
            ? L("sin carpetas todavía")
            : plural("%ld carpetas", carpetas)
    }
}

// MARK: - Copia

private struct CopiaTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let d = state.selectedDisk {
            let disco = enlace(state, d.id)
            Form {
                Section { CabeceraDeDisco(state: state) }

                Section {
                    Toggle("Sincronizar en cuanto se conecte el disco", isOn: disco.autoSyncOnMount)
                } footer: {
                    Text("Sin esto habrá que darle a «Sincronizar ahora» desde el menú cada vez.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Guardar lo que se borre del Mac", isOn: disco.keepRemoved)
                    if d.keepRemoved {
                        HStack {
                            Text("Guardarlo durante")
                            TextField("", value: disco.removedRetentionDays, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text("días")
                            Spacer()
                        }
                        Text(d.removedRetentionDays == 0
                             ? L("A 0 días no se borra nunca de la papelera del disco.")
                             : L("Pasados %@ se borra de verdad.", plural("%ld días", d.removedRetentionDays)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Lo que se borra")
                } footer: {
                    Text(d.keepRemoved
                         ? "Lo que borres en el Mac no se borra del disco: se aparta a la carpeta _Retirados, con la fecha del día. Es la red bajo un borrado por error."
                         : "⚠︎ Sin esto, borrar algo en el Mac lo borra del disco en la siguiente sincronización, y no hay vuelta atrás.")
                        .font(.caption)
                        .foregroundStyle(d.keepRemoved ? Color.secondary : Color.orange)
                }

                Section {
                    Toggle("Saltarse los archivos de iCloud que no estén descargados",
                           isOn: disco.skipUndownloadediCloud)
                } footer: {
                    Text("Copiarlos obligaría a bajarlos primero, que es justo lo que nadie espera al enchufar un disco.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            SinDiscos()
        }
    }
}

// MARK: - Exclusiones

private struct ExclusionesTab: View {
    @ObservedObject var state: AppState
    @State private var nuevo = ""
    @State private var seleccion: String?

    var body: some View {
        if let d = state.selectedDisk {
            VStack(spacing: 0) {
                Form { Section { CabeceraDeDisco(state: state) } }
                    .formStyle(.grouped)
                    .frame(height: 70)

                List(selection: $seleccion) {
                    ForEach(d.excludes, id: \.self) { p in
                        Text(p).font(.system(.callout, design: .monospaced)).tag(p)
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack(spacing: 8) {
                    TextField("Nombre a excluir, p. ej. *.log", text: $nuevo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { anadir(d) }
                    Button("Añadir") { anadir(d) }
                        .disabled(nuevo.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { quitar(d) } label: { Image(systemName: "minus") }
                        .disabled(seleccion == nil)
                }
                .padding(8)

                Text("Se compara con el nombre del archivo o de la carpeta, no con la ruta entera. Vale un « * » al principio o al final.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            // Al cambiar de disco, lo escrito a medias y lo seleccionado eran
            // de otro: se limpian para no añadírselo al que no era.
            .onChange(of: d.id) { _ in nuevo = ""; seleccion = nil }
        } else {
            SinDiscos()
        }
    }

    private func anadir(_ d: DiskProfile) {
        let p = nuevo.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !d.excludes.contains(p) else { nuevo = ""; return }
        state.config[d.id]?.excludes.append(p)
        nuevo = ""
    }

    private func quitar(_ d: DiskProfile) {
        guard let s = seleccion else { return }
        state.config[d.id]?.excludes.removeAll { $0 == s }
        seleccion = nil
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var state: AppState
    @State private var arrancaSolo = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                // Con un enlace hecho a mano y no con `onChange`: registrar el
                // agente llama a `launchctl` y espera a que termine, así que
                // va a una cola de fondo —si no, la ventana se queda tiesa al
                // pulsar el interruptor—, y de paso la casilla responde al
                // instante y se corrige después con lo que haya pasado de
                // verdad, sin rebotar contra su propio cambio.
                Toggle("Abrir Backup SSD al iniciar sesión", isOn: Binding(
                    get: { arrancaSolo },
                    set: { nuevo in
                        arrancaSolo = nuevo
                        DispatchQueue.global(qos: .userInitiated).async {
                            LoginItem.set(nuevo)
                            let real = LoginItem.isEnabled
                            DispatchQueue.main.async { arrancaSolo = real }
                        }
                    }
                ))
            } footer: {
                Text("Si no está abierta no puede enterarse de que has enchufado el disco.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Aspecto") {
                Picker("Apariencia", selection: $state.config.appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Text("Configuración")
                    Spacer()
                    Button("Mostrar en el Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Config.fileURL])
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("Todo lo de esta ventana vive en ~/.config/backup-ssd/config.json, un archivo de texto que puedes leer, copiar a otro Mac o corregir a mano.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Antes de copiar

/// Fotosync e Itusync: las apps que rellenan carpetas del backup.
///
/// La pestaña existe porque el problema que resuelve no se ve. Las carpetas
/// «Fotos» y «Musica» son carpetas normales y el backup se las lleva sin
/// quejarse; lo que no se nota es que dentro está la exportación de hace tres
/// semanas. Aquí se dice cada cuánto ponerlas al día antes de copiar.
private struct CompanerasTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let d = state.selectedDisk {
            Form {
                Section { CabeceraDeDisco(state: state) }

                ForEach(state.companions) { st in
                    FichaDeCompanera(state: state, estado: st, disk: d)
                }

                Section {
                    Text("Estas apps exportan con enlaces duros: no copian los archivos otra vez ni ocupan espacio en el Mac. Lo que hacen es dejar la carpeta al día para que el disco no se lleve la exportación de la semana pasada.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Se ejecutan **antes** de la copia y sólo en una sincronización de verdad: un ensayo nunca las lanza.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onAppear { state.refreshCompanions() }
        } else {
            SinDiscos()
        }
    }
}

private struct FichaDeCompanera: View {
    @ObservedObject var state: AppState
    let estado: CompanionState
    let disk: DiskProfile

    private var regla: CompanionRule { disk.rule(for: estado.companion) }

    var body: some View {
        Section {
            if !estado.installed {
                Text(L("No está instalada. Exporta %@ a carpetas, y en cuanto esté aquí se podrá poner al día sola antes de cada copia.",
                       estado.companion.what))
                    .font(.callout).foregroundStyle(.secondary)
            } else if estado.destination == nil {
                Text("Está instalada, pero todavía no tiene carpeta de destino. Ábrela y elige una.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !estado.inScope {
                // Ni se ofrece la opción: ejecutarla no cambiaría nada de lo
                // que este disco se lleva.
                Text(L("Exporta a %@, que no está dentro de las carpetas de este disco. Añádela en la ventana principal si quieres que entre en la copia.",
                       acortar(estado.destination ?? "")))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Al conectar el disco", selection: modo) {
                    ForEach(CompanionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if regla.mode == .auto {
                    Picker("Actualizar como mucho", selection: intervalo) {
                        ForEach(CompanionRule.intervals, id: \.self) { h in
                            Text(CompanionRule.intervalLabel(h)).tag(h)
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Última exportación: %@", estado.lastRunText))
                        if !estado.lastOK {
                            Text("La última vez terminó con un problema.")
                                .font(.caption).foregroundStyle(.orange)
                        } else if !estado.lastSummary.isEmpty {
                            Text(estado.lastSummary)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer()
                    Button("Actualizar ahora") { state.runCompanion(estado) }
                        .controlSize(.small)
                        .disabled(state.status.esTrabajando)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(estado.companion.name)
                if estado.relevant, estado.stale(regla), regla.mode != .off {
                    Text("· pendiente")
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            if estado.relevant, let f = estado.folder {
                Text(L("Exporta %1$@ a «%2$@», que sí entra en la copia de este disco.",
                       estado.companion.what, f.name))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var modo: Binding<CompanionMode> {
        Binding(
            get: { regla.mode },
            set: { nuevo in
                var r = regla; r.mode = nuevo
                state.setRule(r, for: estado.companion, on: disk.id)
            })
    }

    private var intervalo: Binding<Int> {
        Binding(
            get: { regla.maxAgeHours },
            set: { nuevo in
                var r = regla; r.maxAgeHours = nuevo
                state.setRule(r, for: estado.companion, on: disk.id)
            })
    }

    private func acortar(_ ruta: String) -> String {
        let casa = NSHomeDirectory()
        return ruta.hasPrefix(casa) ? "~" + ruta.dropFirst(casa.count) : ruta
    }
}
