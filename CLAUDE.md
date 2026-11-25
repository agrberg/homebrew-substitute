# CLAUDE.md

Working notes for AI coding sessions in this repo.

## What this is

A Homebrew tap with one Ruby external command, `brew substitute`. Read [ARCHITECTURE.md](ARCHITECTURE.md) before you change behavior. [README.md](README.md) is the user guide.

## Layout

- `cmd/substitute.rb`: the command and all its modes. The file must stay executable (mode 755) in git.
- `lib/substitution.rb`: the stub keg logic that both commands share.
- `test/integration.rb`: the integration tests. They run in a throwaway Homebrew prefix.
- `bin/style`: runs `brew style agrberg/substitute` with developer mode on for that run only. The file must stay executable (mode 755) in git.
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

`brew style` applies the tap rules and isolates the tap only for a path under `Library/Taps`. This checkout lives at `<sandbox>/Library/Taps/agrberg/homebrew-substitute` (see [CONTRIBUTING.md](CONTRIBUTING.md)), and `./bin/style` runs the brew of that prefix. Pass options after the command: `./bin/style --fix`. The option fixes offenses. It reflows lines, so read the result. `brew typecheck` does not cover taps.

`brew style` is a developer command: without `HOMEBREW_DEVELOPER`, it turns developer mode on for good and prints a notice. `./bin/style` sets `HOMEBREW_DEVELOPER=1` for the run, so nothing stays on. CI sets the variable in the job environment and calls `brew style` directly.

`Homebrew/SingleUseMethod` reports nothing for a symlinked tap until [Homebrew/brew#24773](https://github.com/Homebrew/brew/pull/24773) merges.

## Test procedure

The test procedure, the sandbox and the manual checks are in [CONTRIBUTING.md](CONTRIBUTING.md).
