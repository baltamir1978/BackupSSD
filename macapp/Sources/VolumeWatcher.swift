// Enterarse de que han enchufado el disco. Es la razón de ser del programa.

import AppKit
import Foundation

/// Avisa cuando se monta o se va un volumen.
///
/// Se escucha a `NSWorkspace` y no se pregunta cada pocos segundos: el sondeo
/// gastaría batería para no enterarse de nada el 99 % del tiempo, y llegaría
/// tarde cuando por fin pasara algo.
final class VolumeWatcher {
    /// Se ha montado un disco (ya con su UUID leído).
    var onMount: ((VolumeInfo) -> Void)?
    /// Un disco se va a ir o ya se ha ido. Llega la ruta, porque cuando el
    /// disco ya no está no se le puede preguntar el UUID.
    var onUnmount: ((URL) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private let center = NSWorkspace.shared.notificationCenter

    func start() {
        guard observers.isEmpty else { return }

        observers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.announceMount(url)
        })

        // `willUnmount` y no `didUnmount`: hay que parar de escribir *antes* de
        // que el disco se vaya. Si se espera a que se haya ido, lo que queda a
        // medias es un archivo cortado en el disco de backup.
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                self?.onUnmount?(url)
            })
        }
    }

    func stop() {
        observers.forEach(center.removeObserver(_:))
        observers.removeAll()
    }

    deinit { stop() }

    /// Los discos que ya estaban puestos al arrancar la app.
    ///
    /// Hace falta porque lo normal es tener el disco enchufado desde antes: si
    /// sólo se atendiera a las notificaciones, la app arrancaría sin enterarse
    /// de que su disco lleva ahí toda la mañana.
    func announceAlreadyMounted() {
        for vol in Volumes.mounted() { onMount?(vol) }
    }

    /// Un volumen recién montado tarda un momento en dejarse leer del todo, y
    /// los discos cifrados aparecen y desaparecen mientras se desbloquean. Se
    /// insiste unas cuantas veces antes de darlo por perdido en vez de
    /// anunciar un disco al que todavía no se le puede preguntar el UUID.
    private func announceMount(_ url: URL, intento: Int = 0) {
        if let info = Volumes.info(of: url) {
            onMount?(info)
        } else if intento < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.announceMount(url, intento: intento + 1)
            }
        }
    }
}
