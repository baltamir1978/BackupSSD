// Los discos montados, vistos como los ve la configuración: por UUID.
//
// Esta mitad es sólo Foundation —sin AppKit— para que las pruebas la puedan
// compilar y ejercitar contra los discos que haya de verdad en la máquina.
// La otra mitad, la que se entera de los montajes en cuanto ocurren, vive en
// VolumeWatcher.swift y sí necesita AppKit.

import Foundation

/// Un volumen montado ahora mismo.
struct VolumeInfo: Identifiable, Hashable {
    /// Dónde está montado: `/Volumes/SSD-T7`. Cambia entre conexiones si hay
    /// dos discos con el mismo nombre, así que no sirve para identificarlo.
    var url: URL
    /// Lo que sí identifica al disco, y lo único que se guarda en la
    /// configuración.
    var uuid: String
    var name: String
    var isInternal: Bool
    var isRemovable: Bool

    var id: String { uuid }

    /// Los que tiene sentido ofrecer como destino: primero los externos.
    var looksLikeBackupDisk: Bool { !isInternal || isRemovable }
}

enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey,
    ]

    /// Todos los volúmenes montados que se pueden elegir como destino.
    ///
    /// Se descartan los que no tienen UUID —algunos sistemas de archivos de
    /// red y las imágenes de disco no lo traen—, porque sin UUID no hay forma
    /// de reconocer el disco la próxima vez y todo el programa se apoya en eso.
    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(of:))
            .sorted { ($0.isInternal ? 1 : 0, $0.name.lowercased()) < ($1.isInternal ? 1 : 0, $1.name.lowercased()) }
    }

    static func info(of url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)),
              v.volumeIsBrowsable ?? true,
              let uuid = v.volumeUUIDString, !uuid.isEmpty
        else { return nil }
        return VolumeInfo(
            url: url,
            uuid: uuid,
            name: v.volumeName ?? url.lastPathComponent,
            isInternal: v.volumeIsInternal ?? false,
            isRemovable: (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
        )
    }

    /// El volumen con ese UUID, si está montado ahora mismo.
    static func find(uuid: String) -> VolumeInfo? {
        guard !uuid.isEmpty else { return nil }
        return mounted().first { $0.uuid == uuid }
    }

    /// La raíz del backup dentro del disco: `/Volumes/SSD-T7/Backup-SSD`.
    ///
    /// Se comprueba el UUID del volumen **otra vez**, justo antes de devolver
    /// la ruta, y no se da por bueno lo que se vio al montar. Entre una cosa y
    /// otra el disco puede haberse desmontado y haber llegado otro al mismo
    /// `/Volumes/SSD-T7`; escribir ahí sería copiar en el disco de un
    /// desconocido, y retirar de él lo que no está en el Mac.
    static func backupRoot(config: Config) throws -> URL {
        guard let vol = find(uuid: config.volumeUUID) else {
            throw SyncError.noDestination(config.volumeName.isEmpty ? "del disco" : config.volumeName)
        }
        guard let ahora = info(of: vol.url), ahora.uuid == config.volumeUUID else {
            throw SyncError.wrongVolume(expected: config.volumeName,
                                        found: info(of: vol.url)?.name ?? "otro disco")
        }
        let carpeta = config.rootFolder.trimmingCharacters(in: .whitespaces)
        return vol.url.appendingPathComponent(carpeta.isEmpty ? "Backup-SSD" : carpeta, isDirectory: true)
    }
}
