# Source quality gate

Run `just test-code-quality` from the integration checkout; `just ci` and the Source quality GitHub workflow run the same tests and strict policy.
The checker reads tracked files and nonignored untracked files, including tests and generated source, while excluding dependency and build outputs.
Every owned source file must contain at most 600 physical lines, including blank lines and comments.

Pygments identifies lexical comments, while Python's AST identifies actual module, class and function docstrings.
Adjacent standalone comment lines form one explanation; separate inline comments remain independent.
The tests cover raw and multiline literals, nested comments, interpolations, heredocs, directives, ownership and the exact 600-line boundary.
The checker reports findings and never edits source.
Editorial review remains necessary: a one-line narrative or misplaced invariant can pass the structural check and still need correction.

`notices.json` is empty because no bundled generated source requires a legal-notice exception.
Each exception requires a reason and fails if its exact notice disappears or changes.
Recognised compiler and tooling directives are not explanatory prose.
There are no test or generated-source exemptions, and CI never supplies a debt baseline.

The optional `--baseline` switch supports a temporary non-growing remediation ratchet: each file's existing debt is a ceiling, while new debt fails.
The completed integration remediation uses the strict zero-debt invocation above.
Use `--report <path>` to save source hashes, physical line counts, explanation locations and outstanding findings for review.
