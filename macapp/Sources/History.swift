// El historial: lo que pasó en cada sincronización, guardado en disco para que
// la respuesta a «¿esto se copió?» no dependa de que la app siga abierta desde
// entonces.
//
// Vive aparte de `AppState` y sin AppKit para que las pruebas puedan
// ejercitarlo: es un archivo que se escribe y se vuelve a leer, y de esos hay
// que comprobar siempre el viaje de ida y vuelta.

import Foundation

/// Una sincronización que ya pasó. Se guarda en disco para que la respuesta a
/// «¿esto se copió?» no dependa de que la app siga abierta desde entonces.
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var volumeName = ""
    var copied = 0
    var updated = 0
    var retired = 0
    var moved = 0
    var errors: [String] = []
    /// Cuántos estaban en uso y se volverán a copiar.
    var changed = 0
    /// Cuántos se copiaron al disco pero **no** se borraron del Mac porque no
    /// se pudo comprobar que la copia estuviera bien.
    var unverified = 0
    var bytes: Int64 = 0
    var duration: TimeInterval = 0
    var cancelled = false
    /// Si no llegó a empezar: por qué.
    var failure: String? = nil

    init(report: SyncReport, volume: String) {
        volumeName = volume
        copied = report.copied
        updated = report.updated
        retired = report.retired
        moved = report.moved
        errors = report.errors
        changed = report.changed.count
        unverified = report.unverified.count
        bytes = report.bytesWritten
        duration = report.duration
        cancelled = report.cancelled
    }

    init(failure: String, volume: String) {
        self.failure = failure
        volumeName = volume
    }

    /// Clave a clave, por lo mismo que en `Config`: el `init(from:)` que
    /// sintetiza Swift usa `decode` y no mira los valores por omisión, así que
    /// una clave nueva —`moved`, sin ir más lejos— haría fallar la
    /// decodificación de **todo** el archivo. Como `History.load()` lo intenta
    /// con `try?`, el fallo no se vería: la app arrancaría con el historial en
    /// blanco y parecería que se ha perdido lo de todos estos meses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? ""
        copied = try c.decodeIfPresent(Int.self, forKey: .copied) ?? 0
        updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        retired = try c.decodeIfPresent(Int.self, forKey: .retired) ?? 0
        moved = try c.decodeIfPresent(Int.self, forKey: .moved) ?? 0
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        changed = try c.decodeIfPresent(Int.self, forKey: .changed) ?? 0
        unverified = try c.decodeIfPresent(Int.self, forKey: .unverified) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }

    var ok: Bool { failure == nil && errors.isEmpty && !cancelled }

    var summary: String {
        if let f = failure { return f }
        if cancelled { return L("Detenido — %@ copiados antes de parar", plural("%ld archivos", copied + updated + moved)) }
        var partes: [String] = []
        if copied > 0 { partes.append(plural("%ld nuevos", copied)) }
        if updated > 0 { partes.append(plural("%ld actualizados", updated)) }
        if moved > 0 { partes.append(plural("%ld movidos", moved)) }
        if retired > 0 { partes.append(plural("%ld retirados", retired)) }
        if partes.isEmpty { partes.append(L("sin cambios")) }
        if changed > 0 { partes.append(plural("%ld estaban en uso", changed)) }
        if unverified > 0 { partes.append(plural("%ld sin mover", unverified)) }
        if !errors.isEmpty { partes.append(plural("%ld con error", errors.count)) }
        return partes.joined(separator: ", ")
    }
}

enum History {
    static var fileURL: URL { Config.directory.appendingPathComponent("historial.json") }
    /// Suficiente para mirar atrás unos meses sin que el archivo crezca sin fin.
    static let limit = 100

    /// Dónde se aparta un historial que no se ha podido leer. Ver `load()`.
    static var brokenURL: URL { Config.directory.appendingPathComponent("historial-ilegible.json") }

    static func load() -> [HistoryEntry] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }

        // Con la misma estrategia con la que se escribió. Sin decírselo, el
        // decodificador espera un número donde hay una fecha ISO-8601, la
        // lectura falla **entera**, y como quien llama a esto se queda con una
        // lista vacía, la siguiente sincronización guardaba encima: el
        // historial se perdía en cada arranque sin que nadie se enterara.
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let h = try? iso.decode([HistoryEntry].self, from: d) { return h }
        // Por si queda algún archivo de cuando se escribían como número.
        if let h = try? JSONDecoder().decode([HistoryEntry].self, from: d) { return h }

        // No hay forma de leerlo: se aparta en vez de dejar que la próxima
        // sincronización lo pise. Un historial que no se entiende es un
        // problema; perderlo sin dejar rastro, otro peor.
        try? FileManager.default.removeItem(at: brokenURL)
        try? FileManager.default.moveItem(at: fileURL, to: brokenURL)
        return []
    }

    static func save(_ entries: [HistoryEntry]) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(Array(entries.prefix(limit))) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }
}
