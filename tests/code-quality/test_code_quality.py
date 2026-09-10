"""Exercise the policy boundary before adding it to CI."""

from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from check_code_quality import compare, debt, validate_notices
from code_quality.lexical import inspect
from code_quality.source import is_source, sources


class LexicalPolicyTests(unittest.TestCase):
    def multiline(self, path, text):
        return [item for item in inspect(Path(path), text)['explanations']
                if item['end'] > item['start']]

    def test_strings_and_urls_are_not_comments(self):
        examples = {
            'Example.swift': 'let url = #"https://example.com/a//b"#\nlet s = "/* text */"\n',
            'example.rs': 'let s = r#"// text\n/* text */"#;\n',
            'example.ts': 'const s = `// text\n/* text */`;\n',
            'example.py': 'value = """# text\n# still a string"""\n',
            'example.yaml': 'script: |\n  # literal text\n  # still text\n',
            'example.sh': "cat <<'TEXT'\n# literal text\n# still text\nTEXT\n",
        }
        for path, source in examples.items():
            with self.subTest(path=path):
                self.assertEqual(self.multiline(path, source), [])

    def test_adjacent_standalone_explanations_are_one_block(self):
        for path, marker in [('E.swift', '///'), ('e.rs', '//!'), ('e.py', '#'), ('e.sql', '--')]:
            with self.subTest(path=path):
                found = self.multiline(path, f'{marker} First reason.\n{marker} Continuation.\n')
                self.assertEqual([(x['start'], x['end']) for x in found], [(1, 2)])

    def test_independent_inline_comments_are_not_joined(self):
        source = 'let a = 1 // first unit\nlet b = 2 // different unit\n'
        self.assertEqual(self.multiline('E.swift', source), [])

    def test_inline_and_standalone_comments_are_distinct(self):
        self.assertEqual(self.multiline('e.rs', 'let a = 1; // unit\n// Separate invariant.\n'), [])

    def test_nested_block_comments_include_blank_lines(self):
        found = self.multiline('e.rs', '/* Outer\n\n/* Nested */\nEnd */\n')
        self.assertEqual([(x['start'], x['end']) for x in found], [(1, 4)])

    def test_python_docstrings_use_syntax_not_string_length(self):
        source = 'def example():\n    """First.\n    Second."""\n    value = """Data\nmore data"""\n'
        found = self.multiline('e.py', source)
        self.assertEqual([(x['start'], x['end'], x['kind']) for x in found], [(2, 3, 'docstring')])

    def test_shebang_is_not_an_explanation(self):
        source = '#!/bin/sh\n# One useful reason.\nexit 0\n'
        self.assertEqual(self.multiline('postinst', source), [])

    def test_jsonc_and_tool_directives_are_lexed(self):
        source = '{\n// Explanation\n// continuation\n"url": "https://example.com"\n}\n'
        self.assertEqual(len(self.multiline('wrangler.jsonc', source)), 1)
        self.assertEqual(self.multiline('x.c', '#define VALUE \\\n  1\n'), [])

    def test_physical_lines_include_blanks_comments_and_unterminated_last_line(self):
        self.assertEqual(inspect(Path('e.py'), '# Comment\n\nx = 1')['physical_lines'], 3)

    def test_build_file_comments_are_owned(self):
        for path in ['Makefile', 'Makefile.linux', 'Kbuild', 'Dockerfile', 'Justfile']:
            with self.subTest(path=path):
                self.assertEqual(len(self.multiline(path, '# First reason.\n# Continuation.\n')), 1)

    def test_python_async_class_and_module_docstrings_are_owned(self):
        source = '\"\"\"Module\nreason.\"\"\"\nclass Example:\n    \"\"\"Class\n    reason.\"\"\"\n    async def run(self):\n        \"\"\"Method\n        reason.\"\"\"\n'
        self.assertEqual(len(self.multiline('e.py', source)), 3)

    def test_one_line_explanations_have_no_debt(self):
        for path, source in [('e.rs', '/// One reason.\nfn run() {}\n'), ('e.swift', '/** One reason. */\nstruct Example {}\n'), ('e.py', '\"\"\"One reason.\"\"\"\n')]:
            with self.subTest(path=path):
                self.assertEqual(self.multiline(path, source), [])

    def test_tool_directives_do_not_merge_with_explanations(self):
        for path, source in [('e.ts', '// Preserve shape.\n// prettier-ignore\ntype T = string;\n'), ('e.sh', '# Values are intentionally split.\n# shellcheck disable=SC2086\necho $values\n')]:
            with self.subTest(path=path):
                self.assertEqual(self.multiline(path, source), [])
        self.assertEqual(len(self.multiline('e.ts', '// A reason.\n// prettier-ignore this is unrelated prose\n')), 1)
        self.assertEqual(len(self.multiline('e.swift', '/*\n// prettier-ignore\n*/\n')), 1)

    def test_multiline_eslint_directives_are_preserved(self):
        for directive in ['/* eslint-disable\n  no-alert,\n  no-console\n*/',
                          '/* eslint-enable\n  @typescript-eslint/no-explicit-any\n*/']:
            with self.subTest(directive=directive):
                self.assertEqual(self.multiline('e.ts', directive + '\nconst a = 1;\n'), [])
        source = '/* eslint-disable\nThis is explanatory prose, not a rule list.\n*/\n'
        self.assertEqual(len(self.multiline('e.ts', source)), 1)

    def test_swiftlint_directives_remain_separate_from_explanations(self):
        for directive in ['// swiftlint:disable force_unwrapping',
                          '// swiftlint:disable:next identifier_name type_name',
                          '// swiftlint:enable all']:
            with self.subTest(directive=directive):
                self.assertEqual(self.multiline('e.swift', '// A precise invariant.\n' + directive + '\n'), [])

    def test_multiline_raw_literals_and_real_interpolation_comments(self):
        for path, literal in [('e.swift', 'let text = #"""\n// literal\n/* literal */\n"""#\n'),
                              ('e.rs', 'let text = r###"\n// literal\n/* literal */\n"###;\n')]:
            with self.subTest(path=path):
                self.assertEqual(self.multiline(path, literal), [])
        source = 'const value = `${\n// first reason\n// second reason\n1}`;\n'
        found = self.multiline('e.ts', source)
        self.assertEqual([(item['start'], item['end']) for item in found], [(2, 3)])


class DebtPolicyTests(unittest.TestCase):
    def test_new_test_and_generated_files_are_owned(self):
        for path in ['tests/large.rs', 'Generated/Large.swift', 'vendor/worker-configuration.d.ts',
                     'runtime/crates/sparkd/src/build/mod.rs', 'src/target/parser.rs',
                     'src/dist/index.ts', 'src/venv/config.py', 'docs/build/check.py']:
            self.assertTrue(is_source(Path(path), b''))

    def test_build_and_dependency_outputs_are_excluded(self):
        for path in ['.build/generated.swift', 'runtime/target/output.rs', 'vendor/node_modules/a.ts',
                     'build/output.py', 'dist/bundle.js', 'target/build.rs', 'venv/lib/module.py',
                     'apple/Vendor/SwiftTerm/Sources/SwiftTerm/Terminal.swift']:
            self.assertFalse(is_source(Path(path), b''))

    def test_non_source_artifacts_are_excluded(self):
        for path in ['README.md', 'package-lock.json', 'photo.png']:
            self.assertFalse(is_source(Path(path), b''))

    def test_git_discovery_keeps_authored_build_modules_and_respects_ignored_files(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '--quiet', str(root)], check=True)
            (root / '.gitignore').write_text('ignored/\n', encoding='utf-8')
            owned = {'runtime/crates/sparkd/src/build/artifacts.rs', 'src/target/selector.rs',
                     'src/dist/index.ts', 'Generated/Contract.swift', 'tests/test_model.py'}
            excluded = {'ignored/test.py', 'vendor/node_modules/dep.ts', 'build/output.py',
                        'runtime/target/generated.rs', 'README.md'}
            for relative in owned | excluded:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', 'Generated/Contract.swift'], check=True)
            self.assertEqual({path.relative_to(root).as_posix() for path in sources(root)}, owned)

    def test_600_is_allowed_and_601_is_a_violation(self):
        current = {'e.py': inspect(Path('e.py'), '\n' * 600)}
        self.assertEqual(debt(current, {}), {})
        current['e.py'] = inspect(Path('e.py'), '\n' * 601)
        self.assertEqual(debt(current, {})['e.py']['physical_lines'], 601)

    def test_temporary_debt_cannot_grow_or_move_to_a_new_file(self):
        baseline = {'old.py': {'physical_lines': 700, 'multiline_explanations': 2}}
        self.assertEqual(compare({'old.py': {'physical_lines': 650, 'multiline_explanations': 1}}, baseline), [])
        self.assertEqual(len(compare({'old.py': {'physical_lines': 701}}, baseline)), 1)
        self.assertEqual(len(compare({'new.py': {'multiline_explanations': 1}}, baseline)), 1)

    def test_mandatory_notice_requires_exact_content_and_a_reason(self):
        item = inspect(Path('license.ts'), '/* Copyright owner.\nLicense terms. */\n')
        digest = item['explanations'][0]['sha256']
        inventory = {'license.ts': item}
        notices = {'license.ts': {digest: 'Required upstream license notice.'}}
        self.assertEqual(debt(inventory, notices), {})
        self.assertEqual(validate_notices(inventory, notices), [])
        self.assertEqual(len(validate_notices(inventory, {'license.ts': {digest: ''}})), 1)
        self.assertEqual(len(validate_notices({}, notices)), 1)


if __name__ == '__main__':
    unittest.main()
