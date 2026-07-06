#!/usr/bin/env python3
#/**
# * Copyright 2026 RDK Management
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# * http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *
# * SPDX-License-Identifier: Apache-2.0
# */
"""
aidl_surface - canonical AIDL surface dump + structural diff (#27).

    aidl_ops dump-surface <aidl-root> [--out FILE]
        Parse every .aidl under <aidl-root> and print a canonical,
        deterministic text dump of the declared surface: interfaces,
        parcelables, unions and enums with method signatures, field types,
        enum values + backing ints and AIDL annotations. Comments are
        stripped; types are sorted by qualified name; members keep
        declaration order (it is ABI: transaction ids / parcel order).

    aidl_ops diff-surface <old-dump> <new-dump> [--json]
        Structurally compare two dump-surface outputs and classify:
          breaking - a client built against <old> can break against <new>
                     (member removed / changed / reordered, enum int
                     changed, annotation changed, ...)
          major    - purely additive (member appended, enum value added,
                     new type)
          none     - no structural difference
        Doc-only changes never appear here (comments are stripped at dump
        time): equal dumps + differing sources is the consumer's doc-only
        signal. Exit code is 0 for any successful classification; 2 on
        usage/parse errors.
"""

import json
import os
import re
import sys

DECL_KINDS = ("interface", "parcelable", "union", "enum")
_DECL_RE = re.compile(
    r'^(?P<oneway>oneway\s+)?(?P<kind>interface|parcelable|union|enum)\s+'
    r'(?P<name>\w+)\s*(?P<term>[{;])')
_ANNOTATION_RE = re.compile(r'@\w+(\s*\([^)]*\))?')
_INT_RE = re.compile(r'^[+-]?(0[xX][0-9a-fA-F]+|\d+)$')


# ---------------------------------------------------------------------------
# Parsing .aidl sources
# ---------------------------------------------------------------------------

def _string_end(text, i):
    """Index just past the string literal starting at text[i] == '"'."""
    j, n = i + 1, len(text)
    while j < n and text[j] != '"':
        j += 2 if text[j] == '\\' else 1
    return min(j + 1, n)


def strip_comments(text):
    """Remove // and /* */ comments, preserving string literals."""
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            j = _string_end(text, i)
            out.append(text[i:j])
            i = j
        elif text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
            out.append(' ')
        else:
            out.append(ch)
            i += 1
    return ''.join(out)


def _normalize(stmt):
    """Collapse whitespace and normalize punctuation spacing — but only
    OUTSIDE string literals, so const/default string values are preserved
    verbatim and a change inside a string always shows in the dump."""
    out = ''
    i, n = 0, len(stmt)
    buf = ''

    def flush(segment):
        segment = re.sub(r'\s+', ' ', segment)
        segment = re.sub(r'\s*([(),;=\[\]])\s*', r'\1', segment)
        segment = segment.replace(',', ', ').replace('=', ' = ')
        # `Codec[] name`, not `Codec[]name`; '(' after identifier stays tight.
        return re.sub(r'\](\w)', r'] \1', segment)

    while i < n:
        if stmt[i] == '"':
            j = _string_end(stmt, i)
            out += flush(buf) + stmt[i:j]
            buf = ''
            i = j
        else:
            buf += stmt[i]
            i += 1
    return (out + flush(buf)).strip()


def _split_statements(body):
    """Split a declaration body into top-level statements.

    Yields (kind, text) where kind is 'decl' for a nested type declaration
    (text = (header, inner_body)) or 'stmt' for a ';'-terminated statement.
    """
    i, n = 0, len(body)
    buf = ''
    while i < n:
        ch = body[i]
        if ch == '"':
            # string literals are opaque: ; { } inside them are not structure
            j = _string_end(body, i)
            buf += body[i:j]
            i = j
        elif ch == '{':
            # matched-brace body for a nested declaration (string-aware)
            depth, j = 1, i + 1
            while j < n and depth:
                if body[j] == '"':
                    j = _string_end(body, j)
                    continue
                depth += {'{': 1, '}': -1}.get(body[j], 0)
                j += 1
            yield ('decl', (buf.strip(), body[i + 1:j - 1]))
            buf = ''
            i = j
        elif ch == ';':
            if buf.strip():
                yield ('stmt', buf.strip())
            buf = ''
            i += 1
        else:
            buf += ch
            i += 1
    if buf.strip():
        yield ('stmt', buf.strip())


def _take_annotations(text):
    """Split leading annotations off a declaration/statement."""
    anns = []
    rest = text.strip()
    while True:
        m = _ANNOTATION_RE.match(rest)
        if not m:
            return anns, rest
        anns.append(re.sub(r'\s+', '', m.group(0)))
        rest = rest[m.end():].strip()


def _parse_enum_body(body):
    """Enum values with computed backing ints where derivable."""
    members = []
    prev = -1
    for value in body.split(','):
        value = value.strip()
        if not value:
            continue
        if '=' in value:
            name, _, expr = value.partition('=')
            name, expr = name.strip(), expr.strip()
            if _INT_RE.match(expr):
                prev = int(expr, 0)
                members.append('%s = %d' % (name, prev))
            else:
                members.append('%s = %s' % (name, _normalize(expr)))
                prev = None
        else:
            prev = None if prev is None else prev + 1
            members.append(
                '%s = %d' % (value, prev) if prev is not None else value)
    return members


def _parse_type(header, body, package, outer, types):
    anns, rest = _take_annotations(header)
    m = _DECL_RE.match(rest + ' {')
    if not m:
        return
    kind, name = m.group('kind'), m.group('name')
    oneway = bool(m.group('oneway'))
    qname = '.'.join(x for x in (package, outer, name) if x)
    members = []
    if kind == 'enum':
        members = _parse_enum_body(body)
    else:
        for skind, item in _split_statements(body):
            if skind == 'decl':
                _parse_type(item[0], item[1], package,
                            '.'.join(x for x in (outer, name) if x), types)
            else:
                members.append(_normalize(item))
    types[qname] = {
        'kind': kind,
        'oneway': oneway,
        'annotations': sorted(anns),
        'members': members,
    }


def parse_aidl(text, types):
    """Parse one .aidl file's text into the types dict."""
    text = strip_comments(text)
    package = ''
    pm = re.search(r'^\s*package\s+([\w.]+)\s*;', text, re.M)
    if pm:
        package = pm.group(1)
    # Remove package/import statements, then parse top-level declarations.
    text = re.sub(r'^\s*(package|import)\s+[\w.*]+\s*;', '', text,
                  flags=re.M)
    for skind, item in _split_statements(text):
        if skind == 'decl':
            _parse_type(item[0], item[1], package, '', types)
        else:
            # Unstructured forward declaration: `parcelable X;`
            anns, rest = _take_annotations(item)
            m = _DECL_RE.match(rest + ' ;')
            if m:
                qname = '.'.join(
                    x for x in (package, m.group('name')) if x)
                types[qname] = {
                    'kind': m.group('kind'),
                    'oneway': False,
                    'annotations': sorted(anns),
                    'members': [],
                }


def dump_surface(aidl_root):
    """Canonical text dump of every .aidl under aidl_root."""
    types = {}
    for dirpath, dirnames, filenames in os.walk(aidl_root):
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith('.aidl'):
                # errors='replace': stray non-UTF8 bytes (latin-1 NBSP has
                # been seen in real corpora) must not abort the dump, and
                # the replacement is deterministic.
                with open(os.path.join(dirpath, fn), 'r',
                          encoding='utf-8', errors='replace') as f:
                    parse_aidl(f.read(), types)
    lines = []
    for qname in sorted(types):
        t = types[qname]
        head = ' '.join(
            t['annotations']
            + (['oneway'] if t['oneway'] else [])
            + [t['kind'], qname])
        lines.append(head)
        lines.extend('    ' + m for m in t['members'])
        lines.append('')
    return '\n'.join(lines)


# ---------------------------------------------------------------------------
# Diffing two dumps
# ---------------------------------------------------------------------------

def parse_dump(text):
    """Parse dump-surface output back into {qname: type} structures."""
    types = {}
    cur = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line.startswith('    '):
            if cur is not None:
                cur['members'].append(line.strip())
            continue
        anns, rest = _take_annotations(line)
        parts = rest.split()
        oneway = parts and parts[0] == 'oneway'
        if oneway:
            parts = parts[1:]
        if len(parts) != 2 or parts[0] not in DECL_KINDS:
            raise ValueError('bad dump header line: %r' % line)
        cur = {
            'kind': parts[0],
            'oneway': oneway,
            'annotations': sorted(anns),
            'members': [],
        }
        types[parts[1]] = cur
    return types


def _member_name(kind, member):
    """The identity of a member line: its declared name."""
    if kind == 'enum' or member.startswith('const '):
        return member.split('=')[0].split()[-1].strip()
    m = re.match(r'[^(=]*?(\w+)\s*\(', member)   # method
    if m:
        return m.group(1)
    return member.split('=')[0].split()[-1].strip()  # field


def _diff_sequence(kind, where, old, new, added_kind, changes):
    """Order-aware member diff. Removal/change/reorder = breaking;
    append-only = major (declaration order is ABI)."""
    old_names = [_member_name(kind, m) for m in old]
    new_names = [_member_name(kind, m) for m in new]
    new_by_name = dict(zip(new_names, new))
    old_by_name = dict(zip(old_names, old))

    for name, member in old_by_name.items():
        if name not in new_by_name:
            changes.append({
                'class': 'breaking',
                'kind': added_kind.replace('added', 'removed'),
                'where': where, 'symbol': name, 'old': member,
            })
        elif new_by_name[name] != member:
            changes.append({
                'class': 'breaking',
                'kind': added_kind.replace('added', 'changed'),
                'where': where, 'symbol': name,
                'old': member, 'new': new_by_name[name],
            })
    survivors = [n for n in old_names if n in new_by_name]
    if new_names[:len(survivors)] != survivors:
        changes.append({
            'class': 'breaking',
            'kind': added_kind.replace('added', 'reordered'),
            'where': where,
            'symbol': ', '.join(survivors),
        })
        return
    for name in new_names[len(survivors):]:
        if name not in old_by_name:
            changes.append({
                'class': 'major', 'kind': added_kind,
                'where': where, 'symbol': new_by_name[name],
            })


def _diff_enum(where, old, new, changes, prefix='enum_value'):
    """Enums/consts match by declared name; the backing int / value is the
    wire contract, not order. `prefix` names the change kinds
    (enum_value_* or const_*)."""
    def as_map(members):
        # Key by the declared identifier (last word before '='), so a
        # const type change reports as one *_changed, not removed+added.
        return {m.split('=')[0].split()[-1].strip(): m for m in members}
    om, nm = as_map(old), as_map(new)
    for name, member in sorted(om.items()):
        if name not in nm:
            changes.append({'class': 'breaking', 'kind': prefix + '_removed',
                            'where': where, 'symbol': name, 'old': member})
        elif nm[name] != member:
            changes.append({'class': 'breaking', 'kind': prefix + '_changed',
                            'where': where, 'symbol': name,
                            'old': member, 'new': nm[name]})
    for name, member in sorted(nm.items()):
        if name not in om:
            changes.append({'class': 'major', 'kind': prefix + '_added',
                            'where': where, 'symbol': member})


def diff_surface(old_text, new_text):
    """Classify new vs old dump: breaking / major / none + change list."""
    old_types, new_types = parse_dump(old_text), parse_dump(new_text)
    changes = []
    for qname in sorted(set(old_types) | set(new_types)):
        o, n = old_types.get(qname), new_types.get(qname)
        if n is None:
            changes.append({'class': 'breaking', 'kind': 'type_removed',
                            'where': '%s %s' % (o['kind'], qname),
                            'symbol': qname})
            continue
        if o is None:
            changes.append({'class': 'major', 'kind': 'type_added',
                            'where': '%s %s' % (n['kind'], qname),
                            'symbol': qname})
            continue
        where = '%s %s' % (n['kind'], qname)
        if o['kind'] != n['kind'] or o['oneway'] != n['oneway']:
            changes.append({'class': 'breaking', 'kind': 'type_changed',
                            'where': where, 'symbol': qname,
                            'old': '%s%s' % ('oneway ' if o['oneway'] else '',
                                             o['kind']),
                            'new': '%s%s' % ('oneway ' if n['oneway'] else '',
                                             n['kind'])})
        removed = set(o['annotations']) - set(n['annotations'])
        added = set(n['annotations']) - set(o['annotations'])
        for a in sorted(removed):
            changes.append({'class': 'breaking', 'kind': 'annotation_removed',
                            'where': where, 'symbol': a})
        for a in sorted(added):
            # A new stability promise is additive; anything else (@Backing,
            # @FixedSize, ...) changes the wire/ABI contract.
            changes.append({
                'class': 'major' if a == '@VintfStability' else 'breaking',
                'kind': 'annotation_added', 'where': where, 'symbol': a})
        if o['kind'] == 'enum':
            _diff_enum(where, o['members'], n['members'], changes)
        else:
            o_const = [m for m in o['members'] if m.startswith('const ')]
            n_const = [m for m in n['members'] if m.startswith('const ')]
            o_rest = [m for m in o['members'] if not m.startswith('const ')]
            n_rest = [m for m in n['members'] if not m.startswith('const ')]
            _diff_enum(where, o_const, n_const, changes, prefix='const')
            member_kind = ('method_added' if o['kind'] == 'interface'
                           else 'field_added')
            _diff_sequence(o['kind'], where, o_rest, n_rest,
                           member_kind, changes)
    overall = 'none'
    if any(change['class'] == 'breaking' for change in changes):
        overall = 'breaking'
    elif any(change['class'] == 'major' for change in changes):
        overall = 'major'
    for change in changes:
        del change['class']
    return {'class': overall, 'changes': changes}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv):
    if not argv or argv[0] in ('-h', '--help', 'help'):
        print(__doc__)
        return 0
    op, args = argv[0], argv[1:]
    if op == 'dump-surface':
        out = None
        if '--out' in args:
            i = args.index('--out')
            if i + 1 >= len(args):
                sys.stderr.write('dump-surface: --out needs a file\n')
                return 2
            out = args[i + 1]
            args = args[:i] + args[i + 2:]
        if len(args) != 1 or not os.path.isdir(args[0]):
            sys.stderr.write(
                'usage: dump-surface <aidl-root> [--out FILE]\n')
            return 2
        text = dump_surface(args[0])
        if out:
            with open(out, 'w', encoding='utf-8', newline='\n') as f:
                f.write(text)
        else:
            sys.stdout.write(text)
        return 0
    if op == 'diff-surface':
        as_json = '--json' in args
        args = [a for a in args if a != '--json']
        if len(args) != 2:
            sys.stderr.write(
                'usage: diff-surface <old-dump> <new-dump> [--json]\n')
            return 2
        try:
            texts = []
            for p in args:
                with open(p, 'r', encoding='utf-8',
                          errors='replace') as f:
                    texts.append(f.read())
            report = diff_surface(texts[0], texts[1])
        except (OSError, ValueError) as e:
            sys.stderr.write('diff-surface: %s\n' % e)
            return 2
        if as_json:
            print(json.dumps(report, indent=2))
        else:
            print('class: %s' % report['class'])
            for change in report['changes']:
                line = '  %s  %s  %s' % (
                    change['kind'], change['where'], change['symbol'])
                if 'old' in change:
                    line += '  [old: %s]' % change['old']
                if 'new' in change:
                    line += '  [new: %s]' % change['new']
                print(line)
        return 0
    sys.stderr.write('aidl_surface: unknown operation %r\n' % op)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
