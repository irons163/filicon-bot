#!/usr/bin/env python3
"""Check UI localization coverage, duplicate keys, and interpolation integrity."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / 'Sources/Filicon/Resources'
LANGUAGES = ('en', 'zh-Hant', 'zh-Hans', 'fr', 'es', 'ja', 'ko')
UI_CALL = re.compile(r'\b(?:Text|Button|Label|Section|Picker|TextField|SecureField|Toggle|ContentUnavailableView|LabeledContent|Window|CommandMenu|Link|GroupBox|DisclosureGroup|Menu)\s*\(|\.(?:help|navigationTitle|alert|confirmationDialog|accessibilityLabel|accessibilityHint)\s*\(')

def string_end(source, start):
    """Walk a Swift string, including balanced nested string interpolation."""
    i = start + 1
    while i < len(source):
        if source.startswith('\\(', i):
            i = balanced_end(source, i + 1)
        elif source[i] == '\\':
            i += 2
        elif source[i] == '"':
            return i + 1
        else:
            i += 1
    raise ValueError('Unterminated string')

def balanced_end(source, start):
    depth, i = 1, start + 1
    while depth:
        if source[i] == '"':
            i = string_end(source, i)
            continue
        if source[i] == '(':
            depth += 1
        elif source[i] == ')':
            depth -= 1
        i += 1
    return i

def key_for(literal):
    value, i, index = '', 1, 0
    while i < len(literal) - 1:
        if literal.startswith('\\(', i):
            value += '{' + str(index) + '}'
            index += 1
            i = balanced_end(literal, i + 1)
        elif literal[i] == '\\':
            value += {'n': '\n', 't': '\t', 'r': '\r'}.get(literal[i + 1], literal[i + 1])
            i += 2
        else:
            value += literal[i]
            i += 1
    return value

def entries(path):
    pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', path.read_text())
    return [(json.loads(k), json.loads(v)) for k, v in pairs]

def source_keys():
    keys = set()
    for path in (ROOT / 'Sources/Filicon').glob('*.swift'):
        source = path.read_text()
        for match in re.finditer(r'\b(?:l10n|localized|agentString|agentMessageString|FiliconLocalization\.string)\(\s*(")', source):
            start = match.start(1)
            keys.add(key_for(source[start:string_end(source, start)]))
    return keys

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inventory', action='store_true')
    args = parser.parse_args()
    tables, failures = {}, []
    for language in LANGUAGES:
        pairs = entries(RESOURCES / f'{language}.lproj/Localizable.strings')
        tables[language] = dict(pairs)
        if len(pairs) != len(tables[language]):
            failures.append(f'{language}: duplicate keys')
    keys = set(tables['en']) | source_keys()
    for language, table in tables.items():
        missing = keys - table.keys()
        print(f'{language}: {len(table)} keys, {len(missing)} missing')
        if missing:
            failures.append(f'{language}: missing {len(missing)} keys')
        for key, value in table.items():
            if not value.strip() and key.strip():
                failures.append(f'{language}: empty translation: {key}')
            if '▁' in value:
                failures.append(f'{language}: tokenizer artifact: {key}')
            if '](sand-' in key and value != key:
                failures.append(f'{language}: altered internal link: {key}')
            if sorted(re.findall(r'\{\d+\}', key)) != sorted(re.findall(r'\{\d+\}', value)):
                failures.append(f'{language}: placeholders differ: {key}')
    bare = []
    for path in (ROOT / 'Sources/Filicon').glob('*.swift'):
        source = path.read_text()
        if re.search(r'(?:==|!=)\s*l10n\(', source):
            failures.append(f'{path.name}: translated text used as a domain comparison')
        for match in UI_CALL.finditer(source):
            start = match.end()
            while start < len(source) and source[start].isspace():
                start += 1
            if source[start:start + 1] == '"':
                key = key_for(source[start:string_end(source, start)])
                if re.search('[A-Za-z]', key):
                    bare.append(f'{path.name}:{source[:start].count(chr(10)) + 1}: {key}')
    if bare:
        failures.append(f'{len(bare)} UI literals bypass localization')
    if args.inventory:
        print(json.dumps(sorted(keys - tables['en'].keys()), ensure_ascii=False, indent=2))
        print('\n'.join(bare))
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(bool(failures))

if __name__ == '__main__':
    main()
