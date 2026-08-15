#!/usr/bin/env python3
"""Comprueba que las traducciones se correspondan con el código.

Por qué hace falta: una cadena mal traducida no da ningún error. Si la clave
del .strings no coincide byte a byte con el literal del código, macOS no la
encuentra y enseña el original en español. La app arranca igual, se ve casi
bien, y el fallo solo aparece si alguien mira esa pantalla en ese idioma.

Uso:
    ./check_strings.py            → informe
    ./check_strings.py --missing  → además, lista lo que falta por traducir

Salida distinta de cero si hay entradas sobrantes (claves del .strings que
ya no existen en el código): eso es siempre un error, casi siempre una errata.
Las claves sin traducir no fallan —caen de vuelta al español, que es el idioma
base— pero se cuentan.
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"

# El idioma base no tiene Localizable.strings porque sus claves ya son el
# texto que se ve. Sus plurales sí hacen falta: la clave lleva el marcador
# («%ld fotos») y sin la tabla saldría «1 fotos».
BASE_LANG = "es"

# Funciones y modificadores cuyo primer argumento de texto es una clave de
# traducción. Los de SwiftUI (Text, Button…) reciben LocalizedStringKey y los
# busca el propio framework; L() y plural() lo hacen a mano.
LOCALIZING = (
    "L", "plural", "Text", "Button", "Toggle", "Label", "TextField",
    "Picker", "LabeledContent", "help", "accessibilityLabel", "alert",
    "navigationTitle", "confirmationDialog", "Window", "accessibilityValue",
    "accessibilityHint",
)

# Etiquetas de argumento que reciben texto pero no traducible: nombres de
# símbolos SF, cadenas de formato crudas, identificadores.
NOT_TEXT = ("systemImage", "verbatim", "format", "id", "key", "value",
            "systemName", "forResource", "withExtension")

# Un literal de Swift: comillas, con \" y \\ admitidos dentro.
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
# El nombre de función que abre una llamada, mirando hacia atrás desde el "(".
CALLEE = re.compile(r'(\w+)\s*$')
# Etiqueta de argumento justo antes del literal.
LABEL = re.compile(r'(\w+)\s*:\s*$')


def strip_comments(text: str) -> str:
    """Quita comentarios // y /* */ sin tocar lo que haya dentro de comillas."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            m = STRING.match(text, i)
            if m:
                out.append(m.group(0))
                i = m.end()
                continue
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def keys_in_file(text: str) -> set[str]:
    """Claves que un archivo Swift busca en la tabla.

    Se recorre el texto llevando la pila de llamadas abiertas, en vez de mirar
    solo lo que precede al literal: así también se ven los que están dentro de
    un ternario —`Text(a ? "uno" : "otro")`— que son clave igual y son
    justamente los que se olvidan al traducir.
    """
    found: set[str] = set()
    stack: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            m = STRING.match(text, i)
            if not m:
                i += 1
                continue
            key = m.group(1)
            label = LABEL.search(text[max(0, i - 40):i])
            # Un literal con interpolación no es una clave: Swift lo convierte
            # en String antes de que nadie lo busque.
            if (stack and stack[-1] in LOCALIZING
                    and "\\(" not in key
                    and key.strip()
                    and not (label and label.group(1) in NOT_TEXT)):
                found.add(unescape(key))
            i = m.end()
        elif c == "(":
            callee = CALLEE.search(text[max(0, i - 40):i])
            stack.append(callee.group(1) if callee else "")
            i += 1
        elif c == ")":
            if stack:
                stack.pop()
            i += 1
        else:
            i += 1
    return found


def keys_in_code() -> dict[str, set[str]]:
    """Claves del código, y en qué archivo aparece cada una."""
    found: dict[str, set[str]] = {}
    for path in sorted(SOURCES.glob("*.swift")):
        for key in keys_in_file(strip_comments(path.read_text(encoding="utf-8"))):
            found.setdefault(key, set()).add(path.name)
    return found


def keys_in_strings(path: Path) -> set[str]:
    """Claves declaradas en un Localizable.strings."""
    # El formato es un plist antiguo; plistlib no lo lee, así que se parsea
    # a mano. Basta con reconocer líneas "clave" = "valor";
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = strip_comments(line).strip()
        if not line.startswith('"'):
            continue
        m = STRING.match(line)
        if m:
            keys.add(m.group(1))
    return keys


def keys_in_stringsdict(path: Path) -> set[str]:
    with path.open("rb") as fh:
        return set(plistlib.load(fh).keys())


def unescape(key: str) -> str:
    """Los .strings escriben \\n; el literal de Swift lleva el salto real."""
    return key.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


def main() -> int:
    show_missing = "--missing" in sys.argv
    code = keys_in_code()
    # Las claves de plural viven en el .stringsdict; el resto, en el .strings.
    plural_keys = {k for k in code if k.startswith("%ld ") or k.startswith("%d ")}
    plain_keys = set(code) - plural_keys

    problems = 0
    langs = sorted(p for p in RESOURCES.glob("*.lproj") if p.is_dir())
    print(f"{len(plain_keys)} claves de texto y {len(plural_keys)} de plural "
          f"en {len(list(SOURCES.glob('*.swift')))} archivos.\n")

    for lproj in langs:
        lang = lproj.name.removesuffix(".lproj")
        base = lang == BASE_LANG
        strings = lproj / "Localizable.strings"
        sdict = lproj / "Localizable.stringsdict"

        declared = {unescape(k) for k in keys_in_strings(strings)} if strings.exists() else set()
        declared_plural = keys_in_stringsdict(sdict) if sdict.exists() else set()

        orphan = declared - plain_keys
        orphan_plural = declared_plural - plural_keys
        missing = set() if base else plain_keys - declared
        missing_plural = plural_keys - declared_plural

        texts = "los literales del código" if base \
            else f"{len(declared)}/{len(plain_keys)} textos"
        print(f"[{lang}]  {texts}, "
              f"{len(declared_plural)}/{len(plural_keys)} plurales")

        for key in sorted(orphan) + sorted(orphan_plural):
            problems += 1
            print(f"  ERROR  sobra, no existe en el código: {key!r}")

        if show_missing:
            for key in sorted(missing) + sorted(missing_plural):
                print(f"  falta: {key!r}")
        elif missing or missing_plural:
            print(f"  {len(missing) + len(missing_plural)} sin traducir "
                  f"(saldrán en español). Con --missing se listan.")
        print()

    if problems:
        print(f"{problems} entradas sobrantes. Suelen ser una errata de un "
              f"carácter: la traducción existe pero nunca se usa.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
