# SpinMyCan

## Language
Everything written to this repo is in English from now on: commit messages, PR titles and descriptions,
code comments, identifiers, log messages, docs and review comments — including GitHub Actions
workflows (`.github/workflows/*.yml`: step names, comments, echo output), scripts in `tools/` and
Makefile output.

Exceptions:
- User-facing UI strings stay Polish in code — Polish is the String Catalog source language and those
  literals are the localization keys. Add English translations in `Localizable.xcstrings`.
- `README.pl.md` is the Polish README; keep it in sync with `README.md`.
- Existing Polish comments/logs don't need a rewrite; translate them when touching that code.

## Git workflow
- Never commit straight to `main`. Do every change on its own branch (e.g. `feature/…`, `fix/…`,
  `docs/…`, `test/…`), then merge it into `main` with `git merge --no-ff` so a merge commit is
  always created. No fast-forward merges.
- Every app change bumps `MARKETING_VERSION` in all build configurations.
