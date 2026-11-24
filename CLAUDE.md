# CLAUDE.md

Working notes for AI coding sessions in this repo.

## What this is

A Homebrew tap with one Ruby external command, `brew substitute`. Read [ARCHITECTURE.md](ARCHITECTURE.md) before you change behavior. [README.md](README.md) is the user guide.

## Layout

- `cmd/substitute.rb`: the command and all its modes. The file must stay executable (mode 755) in git.
- `lib/substitution.rb`: the stub keg logic that both commands share.
- `test/integration.rb`: the integration tests. They run in a throwaway Homebrew prefix.
- `test/style.rb`: the style check. It runs RuboCop with Homebrew's rules on this checkout.
- `bin/style`: runs `test/style.rb` with developer mode on for that run only. The file must stay executable (mode 755) in git.
- `.github/workflows/ci.yml`: the style check, and the integration tests on macOS and Linux.

## Rules for changes

- Keep every mode in `cmd/substitute.rb`. Brew checks trust for each command file, so a second file means that every user must run a second `brew trust --command`.
- Keep the stub keg layout in ARCHITECTURE.md. Two simpler layouts fail, and one of them deletes the substitute on `brew uninstall`.
- Run every read-only check before any step that changes state.
- Give each new step that changes state a rollback, and restore link states with `Substitution.reinstall_original`.
- `Keg#path` is protected. Use `keg.to_s`.
- Call `brew` through `Substitution.brew`. It uses `SystemCommand.safe_system`. Plain `safe_system` is not available in a module.
- Write `typed: strict` Ruby with Sorbet `sig` blocks, in the style of Homebrew's own commands.
- When behavior changes, add or change a scenario in `test/integration.rb`, and update the verification record in ARCHITECTURE.md and the examples in README.md.
- Commit with explicit paths. Do not use `git add -A`.
- Work on a branch and merge through a pull request. Do not commit to `main`. Name branches `ar/<short-description>` in lowercase.

## Lint

```sh
./bin/style
```

The script applies Homebrew's style rules to `cmd`, `lib` and `test` in this checkout, whether or not the tap is installed. Pass options and files after the command: `./bin/style --autocorrect-all`. The option fixes offenses. It reflows lines, so read the result. `brew typecheck` does not cover taps.

`brew ruby test/style.rb` gives the same result, but `brew ruby` is a developer command: it turns developer mode on for good and prints a notice. `./bin/style` sets `HOMEBREW_DEVELOPER=1` for the run, so nothing stays on. CI sets the variable in the job environment and calls `brew ruby` directly.

`brew style` isolates a tap only under `Library/Taps`. A second copy of the code in the index changes the findings, and Homebrew scopes some rules to `Taps/...` paths. The script runs RuboCop from this directory and moves those paths here. It reads Homebrew's internals (`Library/.rubocop.yml` and `utils/rubocop.rb`), so the weekly CI run finds a Homebrew change that breaks it.

## Test procedure

The test procedure, the sandbox and the manual checks are in [CONTRIBUTING.md](CONTRIBUTING.md).
