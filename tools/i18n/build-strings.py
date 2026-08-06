#!/usr/bin/env python3
"""Genera i Localizable.strings delle 15 lingue da un catalogo unico.

Tenere quindici file .strings allineati a mano significa scoprire una chiave
mancante solo quando l'interfaccia mostra la chiave grezza al posto del testo.
Qui la fonte è una sola e lo script rifiuta di generare se una lingua è
incompleta.

Uso:
    python3 tools/i18n/build-strings.py [--check]

--check verifica soltanto, senza scrivere: utile prima di un commit.
"""
import json
import os
import re
import sys

# Segnaposto di NSString: %@, %d, %ld, %lu, %1$@, %2$d…
PLACEHOLDER = re.compile(r"%(?:\d+\$)?l{0,2}[@dioufxXsc]")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CATALOG = os.path.join(HERE, "catalog.json")
RESOURCES = os.path.join(ROOT, "Resources")

# I codici sono quelli che si aspetta macOS, non i nomi delle cartelle della
# dashboard: jp -> ja, zh_cn -> zh-Hans, zh_tw -> zh-Hant, pt_br -> pt-BR.
LANGUAGES = [
    "en", "it", "de", "es", "fr", "pt-BR", "ro", "hu",
    "pl", "ru", "tr", "ja", "zh-Hans", "zh-Hant", "ur",
]

# La lingua di sviluppo: se una chiave manca altrove, macOS ricade qui.
BASE = "en"


def escape(value):
    """Rende una stringa sicura dentro un file .strings."""
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def load_catalog():
    with open(CATALOG, encoding="utf-8") as handle:
        return json.load(handle)


def validate(catalog):
    """Controlla che ogni chiave esista in ogni lingua e che i segnaposto
    coincidano: un %@ perso in traduzione fa saltare la formattazione a
    runtime, ed è un errore che si vede solo in quella lingua."""
    problems = []

    for key, translations in catalog.items():
        base_text = translations.get(BASE)
        if not base_text:
            problems.append(f"{key}: manca la lingua base '{BASE}'")
            continue

        base_marks = sorted(PLACEHOLDER.findall(base_text))

        for language in LANGUAGES:
            text = translations.get(language)
            if not text:
                problems.append(f"{key}: manca '{language}'")
                continue

            marks = sorted(PLACEHOLDER.findall(text))
            if marks != base_marks:
                problems.append(
                    f"{key} [{language}]: segnaposto diversi dalla base "
                    f"({marks} invece di {base_marks})"
                )

    return problems


def write_strings(catalog):
    for language in LANGUAGES:
        directory = os.path.join(RESOURCES, f"{language}.lproj")
        os.makedirs(directory, exist_ok=True)

        lines = [
            "/* Generato da tools/i18n/build-strings.py — non modificare a mano.",
            "   Le traduzioni vivono in tools/i18n/catalog.json. */",
            "",
        ]
        for key in sorted(catalog):
            comment = catalog[key].get("comment")
            if comment:
                lines.append(f"/* {comment} */")
            lines.append(f'"{key}" = "{escape(catalog[key][language])}";')
            lines.append("")

        path = os.path.join(directory, "Localizable.strings")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines))

    print(f"Scritte {len(LANGUAGES)} lingue × {len(catalog)} chiavi in Resources/*.lproj")


def main():
    catalog = load_catalog()
    problems = validate(catalog)

    if problems:
        print(f"Catalogo incompleto: {len(problems)} problemi\n")
        for problem in problems[:40]:
            print(f"  - {problem}")
        if len(problems) > 40:
            print(f"  … e altri {len(problems) - 40}")
        return 1

    print(f"Catalogo valido: {len(catalog)} chiavi × {len(LANGUAGES)} lingue")
    if "--check" not in sys.argv:
        write_strings(catalog)
    return 0


if __name__ == "__main__":
    sys.exit(main())
