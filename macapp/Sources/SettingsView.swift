// Los ajustes. El de arriba —qué disco— es el que importa; el resto son
// matices que casi nadie tocará.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    /// Fijada a mano, y no dejando que el `TabView` elija: sin selección
    /// explícita se abría por «Copia», y lo primero que hay que hacer aquí
    /// —elegir el disco— quedaba en una pestaña que nadie había pulsado.
    @State private var pestana = Pestana.disco

    private enum Pestana: Hashable { case disco, copia, excluir, general }

    var body: some View {
        TabView(selection: $pestana) {
            DiscoTab(state: state)
                .tabItem { Label("Disco", systemImage: "externaldrive") }
                .tag(Pestana.disco)
            CopiaTab(state: state)
                .tabItem { Label("Copia", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Pestana.copia)
            ExclusionesTab(state: state)
                .tabItem { Label("Excluir", systemImage: "nosign") }
                .tag(Pestana.excluir)
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pestana.general)
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - Disco

private struct DiscoTab: View {
    @ObservedObject var state: AppState

    /// Los externos primero: son los que alguien querría de destino. Los
    /// internos se enseñan también, por si se copia a otra partición del Mac.
    private var discos: [VolumeInfo] {
        state.volumes.filter(\.looksLikeBackupDisk) + state.volumes.filter { !$0.looksLikeBackupDisk }
    }

    var body: some View {
        Form {
            Section {
                if discos.isEmpty {
                    Text("No hay ningún disco externo conectado.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(discos) { d in
                        HStack(spacing: 10) {
                            Image(systemName: d.isInternal ? "internaldrive" : "externaldrive")
                                .foregroundStyle(d.uuid == state.config.volumeUUID ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name)
                                Text(d.uuid)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if d.uuid == state.config.volumeUUID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Elegir") { state.chooseVolume(d) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Recordar el disco elegido aunque no esté puesto: si sólo se
                // pudieran ver los conectados, quien abre los ajustes sin el
                // disco encima creería que ha perdido la configuración.
                if !state.config.volumeUUID.isEmpty,
                   !discos.contains(where: { $0.uuid == state.config.volumeUUID }) {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.questionmark").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.config.volumeName.isEmpty ? "El disco elegido" : state.config.volumeName)
                            Text("elegido, ahora mismo no conectado")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Olvidar") {
                            state.config.volumeUUID = ""
                            state.config.volumeName = ""
                            state.refreshVolume()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Disco de destino")
            } footer: {
                Text("El disco se recuerda por su identificador, no por su nombre: dos discos pueden llamarse igual y copiar en el que no es sería un desastre.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Carpeta dentro del disco", text: $state.config.rootFolder)
            } footer: {
                Text("Todo cuelga de esta carpeta, para que el disco pueda tener además otras cosas que Backup SSD no toca nunca.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // La lista se mantiene sola: `AppState` la rehace en cuanto se monta o
        // se quita cualquier disco. Aquí sólo se pide una vez al abrir, por si
        // algo cambió mientras la ventana estaba cerrada.
        .onAppear { state.reloadVolumes() }
    }
}

// MARK: - Copia

private struct CopiaTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Sincronizar en cuanto se conecte el disco", isOn: $state.config.autoSyncOnMount)
            } footer: {
                Text("Sin esto habrá que darle a «Sincronizar ahora» desde el menú cada vez.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Guardar lo que se borre del Mac", isOn: $state.config.keepRemoved)
                if state.config.keepRemoved {
                    HStack {
                        Text("Guardarlo durante")
                        TextField("", value: $state.config.removedRetentionDays, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("días")
                        Spacer()
                    }
                    Text(state.config.removedRetentionDays == 0
                         ? L("A 0 días no se borra nunca de la papelera del disco.")
                         : L("Pasados %@ se borra de verdad.", plural("%ld días", state.config.removedRetentionDays)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Lo que se borra")
            } footer: {
                Text(state.config.keepRemoved
                     ? "Lo que borres en el Mac no se borra del disco: se aparta a la carpeta _Retirados, con la fecha del día. Es la red bajo un borrado por error."
                     : "⚠︎ Sin esto, borrar algo en el Mac lo borra del disco en la siguiente sincronización, y no hay vuelta atrás.")
                    .font(.caption)
                    .foregroundStyle(state.config.keepRemoved ? Color.secondary : Color.orange)
            }

            Section {
                Toggle("Saltarse los archivos de iCloud que no estén descargados",
                       isOn: $state.config.skipUndownloadediCloud)
            } footer: {
                Text("Copiarlos obligaría a bajarlos primero, que es justo lo que nadie espera al enchufar un disco.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Exclusiones

private struct ExclusionesTab: View {
    @ObservedObject var state: AppState
    @State private var nuevo = ""
    @State private var seleccion: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $seleccion) {
                ForEach(state.config.excludes, id: \.self) { p in
                    Text(p).font(.system(.callout, design: .monospaced)).tag(p)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 8) {
                TextField("Nombre a excluir, p. ej. *.log", text: $nuevo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(anadir)
                Button("Añadir", action: anadir)
                    .disabled(nuevo.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { quitar() } label: { Image(systemName: "minus") }
                    .disabled(seleccion == nil)
            }
            .padding(8)

            Text("Se compara con el nombre del archivo o de la carpeta, no con la ruta entera. Vale un « * » al principio o al final.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    private func anadir() {
        let p = nuevo.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !state.config.excludes.contains(p) else { nuevo = ""; return }
        state.config.excludes.append(p)
        nuevo = ""
    }

    private func quitar() {
        guard let s = seleccion else { return }
        state.config.excludes.removeAll { $0 == s }
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
