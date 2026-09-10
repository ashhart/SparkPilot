"""Count comments lexically and Python docstrings through the syntax tree."""

import ast
from dataclasses import asdict, dataclass
import hashlib
from pathlib import Path
import re

from pygments import lex
from pygments.lexers import get_lexer_by_name, get_lexer_for_filename
from pygments.token import Comment, String

DIRECTIVE = re.compile(r'^(?://\s*(?:prettier-ignore|eslint-(?:disable|enable)(?:-next-line|-line)?\b.*|@ts-(?:check|nocheck|ignore|expect-error)\b.*|swiftlint:(?:disable|enable)(?::(?:previous|this|next))?\s+\w+(?:\s+\w+)*)|#\s*shellcheck\s+\S.*|/\*\s*eslint-(?:disable|enable)\b.*\*/|///\s*<reference\b.*?/>)$')
ESLINT_BLOCK_DIRECTIVE = re.compile(
    r'/\*\s*eslint-(?:disable|enable)\b\s*'
    r'(?:[\w@][\w@./-]*(?:\s*,\s*[\w@][\w@./-]*)*,?)?\s*\*/'
)


def is_directive(value: str) -> bool:
    value = value.strip()
    return (('\n' not in value and DIRECTIVE.fullmatch(value) is not None)
            or ESLINT_BLOCK_DIRECTIVE.fullmatch(value) is not None)


@dataclass(frozen=True)
class Explanation:
    start: int
    end: int
    kind: str
    text: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.text.encode('utf-8')).hexdigest()


def lexer_for(path: Path):
    aliases = {
        '.mts': 'typescript', '.cts': 'typescript', '.mjs': 'javascript',
        '.cjs': 'javascript', '.metal': 'cpp', '.cuh': 'cpp',
        '.jsonc': 'json',
    }
    if path.suffix in aliases:
        return get_lexer_by_name(aliases[path.suffix], stripnl=False, ensurenl=False)
    if path.name == 'Dockerfile':
        return get_lexer_by_name('docker', stripnl=False, ensurenl=False)
    if path.name in {'Makefile', 'Kbuild'} or path.name.startswith('Makefile.'):
        return get_lexer_by_name('make', stripnl=False, ensurenl=False)
    if path.name == 'Justfile' or not path.suffix:
        return get_lexer_by_name('bash', stripnl=False, ensurenl=False)
    return get_lexer_for_filename(path.name, stripnl=False, ensurenl=False)


def comment_tokens(path: Path, text: str):
    pending = None
    for kind, value in lex(text, lexer_for(path)):
        if (pending is not None and kind in Comment.Single
                and pending[0] == kind and '\n' not in pending[1]):
            pending = (kind, pending[1] + value)
        else:
            if pending is not None:
                yield pending
            pending = (kind, value)
    if pending is not None:
        yield pending


def comments(path: Path, text: str) -> list[Explanation]:
    pieces: dict[int, list[str]] = {}
    occupied: set[int] = set()
    spanning: set[tuple[int, int]] = set()
    number = 1
    for kind, value in comment_tokens(path, text):
        rust_doc = path.suffix == '.rs' and kind in String.Doc and value.startswith(('//', '/*'))
        is_comment = (kind in Comment and kind not in Comment.Preproc) or rust_doc
        if is_comment and is_directive(value):
            is_comment = False
        if number == 1 and value.startswith('#!'):
            is_comment = False
        trimmed = value.rstrip('\r\n')
        if is_comment and '\n' in trimmed:
            spanning.add((number, number + trimmed.count('\n')))
        for offset, part in enumerate(value.split('\n')):
            current = number + offset
            if is_comment:
                if part.strip() or (0 < offset < value.count('\n')):
                    pieces.setdefault(current, []).append(part)
            elif part.strip():
                occupied.add(current)
        number += value.count('\n')
    groups: list[Explanation] = []
    for number, parts in sorted(pieces.items()):
        content = ''.join(parts).strip()
        if groups:
            previous = groups[-1]
            same_block = any(a <= previous.end < number <= b for a, b in spanning)
            standalone = number not in occupied and previous.end not in occupied
            if number == previous.end + 1 and (same_block or standalone):
                groups[-1] = Explanation(previous.start, number, 'comment', previous.text + '\n' + content)
                continue
        groups.append(Explanation(number, number, 'comment', content))
    return groups


def docstrings(path: Path, text: str) -> list[Explanation]:
    if path.suffix != '.py':
        return []
    tree = ast.parse(text, filename=str(path))
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        if not node.body or not isinstance(node.body[0], ast.Expr):
            continue
        value = node.body[0].value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            found.append(Explanation(value.lineno, value.end_lineno, 'docstring',
                                     ast.get_source_segment(text, value) or ''))
    return found


def inspect(path: Path, text: str) -> dict:
    explanations = comments(path, text) + docstrings(path, text)
    return {
        'physical_lines': len(text.splitlines()),
        'sha256': hashlib.sha256(text.encode('utf-8')).hexdigest(),
        'explanations': [asdict(item) | {'sha256': item.sha256} for item in explanations],
    }
