// El dibujo del disco: el mismo objeto que hay encima de la mesa.
//
// Antes se usaba `externaldrive` de SF Symbols, que es un cajón gris con una
// muesca y sirve igual para un disco duro de sobremesa que para un pendrive.
// Aquí el disco es el protagonista —es lo que se enchufa, lo que se expulsa y
// lo que puede no ser el que era—, así que merece un dibujo propio: el cuerpo
// apaisado, la esquina del ojal y el nervado de goma de un SSD portátil, con
// el punto de luz haciendo de indicador de estado.
//
// Va dibujado con formas y no con un PNG por dos motivos: se ve nítido a
// cualquier tamaño —16 px en una fila y 44 px en la cabecera—, y el color sale
// del estado en vez de tener que mantener cuatro imágenes casi iguales.

import SwiftUI

/// Qué le pasa al disco ahora mismo, en lo que hace falta para dibujarlo.
///
/// No es `SyncStatus`: aquí sólo importa cómo se pinta, y `.copiando` y
/// `.comparando` se ven igual. Traducir el uno al otro se hace en `init(_:)`,
/// abajo, para que ninguna vista tenga que decidirlo por su cuenta.
enum EstadoDelDisco {
    case sinDisco
    case listo
    case trabajando
    case fallo
}

/// Un SSD portátil, dibujado a escala.
///
/// `size` es el **ancho**; el alto sale de la proporción del cacharro real
/// (algo más ancho que alto). Se le pasa el ancho y no un `frame` de fuera
/// porque el grosor de los nervios, el radio de las esquinas y el tamaño del
/// punto se calculan a partir de él: escalar el resultado con `.scaleEffect`
/// dejaría los detalles borrosos o gruesos de más.
struct DiscoExterno: View {
    var estado: EstadoDelDisco = .listo
    var size: CGFloat = 28
    /// Gira las flechas mientras se copia. Se puede apagar donde no convenga
    /// —una fila de una lista larga, sin ir más lejos—.
    var animado = true

    /// La proporción del disco: 100 × 52 mm de verdad, redondeado a algo que
    /// no parezca una tarjeta de crédito en un icono pequeño.
    private var alto: CGFloat { (size * 0.62).rounded() }
    private var radio: CGFloat { alto * 0.26 }
    /// Por debajo de esto no caben ni los nervios ni el ojal: a 16 px lo único
    /// que se lee es la silueta y el punto de luz.
    private var conDetalle: Bool { size >= 22 }

    var body: some View {
        ZStack {
            cuerpo
            if conDetalle { nervios }
            brillo
            luz
        }
        .frame(width: size, height: alto)
        .compositingGroup()
        .shadow(color: .black.opacity(estado == .sinDisco ? 0.10 : 0.22),
                radius: size * 0.06, x: 0, y: size * 0.03)
        .opacity(estado == .sinDisco ? 0.8 : 1)
        .grayscale(estado == .sinDisco ? 1 : 0)
        .accessibilityHidden(true)
    }

    // MARK: Las piezas

    /// La carcasa, con el ojal recortado de verdad.
    ///
    /// El agujero se hace restando —`.destinationOut` sobre el grupo entero— y
    /// no pintando un círculo del color del fondo: así se ve el fondo que haya
    /// detrás, sea la lista, la cabecera o el material translúcido de la
    /// ventana, en claro y en oscuro.
    private var cuerpo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radio, style: .continuous)
                .fill(gradienteCuerpo)
            RoundedRectangle(cornerRadius: radio, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: max(0.6, size * 0.018))

            if conDetalle {
                // El ojal: la esquina perforada por donde pasa el mosquetón.
                Circle()
                    .frame(width: alto * 0.22, height: alto * 0.22)
                    .offset(x: -size * 0.5 + alto * 0.22, y: -alto * 0.5 + alto * 0.22)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }

    /// El nervado de goma, en diagonal como el del cacharro de verdad.
    private var nervios: some View {
        Canvas { ctx, tam in
            let paso = tam.height * 0.16
            var x = -tam.height
            var linea = Path()
            while x < tam.width + tam.height {
                linea.move(to: CGPoint(x: x, y: tam.height))
                linea.addLine(to: CGPoint(x: x + tam.height, y: 0))
                x += paso
            }
            ctx.stroke(linea, with: .color(.white.opacity(0.07)),
                       lineWidth: max(0.5, tam.height * 0.035))
        }
        .clipShape(RoundedRectangle(cornerRadius: radio, style: .continuous))
        .allowsHitTesting(false)
    }

    /// El reflejo de arriba. Es lo que hace que parezca un objeto y no una
    /// pegatina, y lo que lo ata al aspecto del sistema en macOS 26.
    private var brillo: some View {
        RoundedRectangle(cornerRadius: radio, style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.30), location: 0),
                        .init(color: .white.opacity(0.04), location: 0.42),
                        .init(color: .clear, location: 0.55),
                        .init(color: .black.opacity(0.12), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .allowsHitTesting(false)
    }

    /// El punto de luz del disco, que es donde se lee el estado.
    ///
    /// Va donde va en el aparato —abajo, junto al borde— en lugar de ser una
    /// insignia pegada en una esquina: una insignia tapa el dibujo y a 16 px
    /// se convierte en un borrón, y esto se sigue viendo.
    private var luz: some View {
        ZStack {
            if estado == .trabajando {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: alto * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(girando ? 360 : 0))
                    .animation(animado
                               ? .linear(duration: 1.6).repeatForever(autoreverses: false)
                               : nil,
                               value: girando)
                    .onAppear { if animado { girando = true } }
            } else {
                Circle()
                    .fill(colorDeLaLuz)
                    .frame(width: alto * 0.15, height: alto * 0.15)
                    .shadow(color: colorDeLaLuz.opacity(0.9), radius: alto * 0.10)
                    .offset(x: size * 0.30, y: alto * 0.24)
            }
        }
    }

    @State private var girando = false

    // MARK: Colores

    /// Grafito con la esquina cálida del fabricante, que es lo que hace que se
    /// reconozca de un vistazo entre los iconos de la lista.
    private var gradienteCuerpo: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.29, green: 0.30, blue: 0.33), location: 0),
                .init(color: Color(red: 0.16, green: 0.17, blue: 0.19), location: 0.55),
                .init(color: Color(red: 0.11, green: 0.11, blue: 0.13), location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var colorDeLaLuz: Color {
        switch estado {
        case .listo:      return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .fallo:      return Color(red: 1.00, green: 0.35, blue: 0.30)
        case .trabajando: return Color(red: 0.35, green: 0.62, blue: 1.00)
        // Apagado, no gris: el disco que no está no tiene luz encendida.
        case .sinDisco:   return Color(red: 0.45, green: 0.45, blue: 0.48)
        }
    }
}

// MARK: - Del estado de la app al del dibujo

extension EstadoDelDisco {
    init(_ s: SyncStatus) {
        switch s {
        case .sinDisco:              self = .sinDisco
        case .listo:                 self = .listo
        case .actualizando, .comparando, .copiando: self = .trabajando
        case .fallo:                 self = .fallo
        }
    }
}
