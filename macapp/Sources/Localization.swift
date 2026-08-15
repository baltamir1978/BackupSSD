// Localización de las cadenas que no son literales de vista.
//
// Es el mismo mecanismo que en Fotosync e Itusync, y por el mismo motivo:
// SwiftUI localiza solo los literales escritos tal cual dentro de
// Text/Button/Toggle (son LocalizedStringKey y el compilador los busca en la
// tabla). Todo lo que llega ya convertido en `String` —los mensajes de
// problems(), los errores del motor, las líneas del registro, cualquier cosa
// armada con interpolación— se pinta en crudo y no se traduce nunca, aunque
// exista traducción escrita para esa misma frase. Y no da ningún error:
// simplemente sale en español.
//
// De ahí este helper: `L("clave %@", x)` sí pasa por la tabla.
//
// Convenciones:
//   · La clave es la frase en español, que es el idioma base. Si falta la
//     traducción, NSLocalizedString devuelve la propia clave y sale español
//     en vez de un identificador.
//   · Con dos o más argumentos se numeran (`%1$@`, `%2$@`): al traducir, el
//     orden de la frase no siempre coincide con el del español.
//   · Los recuentos van por `plural(...)`, no por `%ld` a secas.

import Foundation

/// Cadena localizada, con formato si se le pasan argumentos.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// Recuento con la forma plural que toque en el idioma activo.
///
/// La regla vive en Localizable.stringsdict, no aquí: cosido a mano con un
/// ternario `n == 1` solo sale bien en español, y hay idiomas —el francés,
/// sin ir más lejos— que tratan el 0 como singular.
func plural(_ key: String, _ count: Int) -> String {
    String(format: NSLocalizedString(key, comment: ""), count)
}
