# CLAUDE.md

Working notes for AI coding sessions in this repo.

## What this is

A Homebrew tap with one Ruby external command, `brew substitute`. Read [ARCHITECTURE.md](ARCHITECTURE.md) before you change behavior. [README.md](README.md) is the user guide.

## Layout

- `cmd/substitute.rb`: the command and all its modes. The file must stay executable (mode 755) in git.
- `lib/substitution.rb`: the stub keg logic that both commands share.
- `test/integration.rb`: the integration tests. They run in a throwaway Homebrew prefix.
- `test/style.rb`: the style check. It runs RuboCop with Homebrew's rules on this checkout.
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
brew ruby test/style.rb
```

The script applies Homebrew's style rules to `cmd`, `lib` and `test` in this checkout, whether or not the tap is installed. Pass options and files after `--`, because `brew ruby` rejects them before it: `brew ruby test/style.rb -- --autocorrect-all`. The option fixes offenses. It reflows lines, so read the result. `brew typecheck` does not cover taps.

`brew style` isolates a tap only under `Library/Taps`. A second copy of the code in the index changes the findings, and Homebrew scopes some rules to `Taps/...` paths. The script runs RuboCop from this directory and moves those paths here. It reads Homebrew's internals (`Library/.rubocop.yml` and `utils/rubocop.rb`), so the weekly CI run finds a Homebrew change that breaks it.

## Test procedure

`test/integration.rb` runs most checks. A few checks (rollback and Ctrl-C) are manual. Run both in a separate Homebrew prefix. Do not test on the user's real install without their approval.

### The sandbox

A checkout of Homebrew/brew is a complete prefix. Running `./bin/brew` inside it uses `Cellar`, `opt`, `var` and `Library/Taps` in that checkout, and git ignores them. Clone Homebrew/brew to make one. Do not put it under `/tmp`: brew refuses a prefix in its temporary directory.

Before any command in the sandbox, set the cache and log directories to a scratch location:

```sh
export HOMEBREW_CACHE=<scratch>/cache HOMEBREW_LOGS=<scratch>/logs HOMEBREW_NO_AUTO_UPDATE=1
```

The sandbox shares `~/Library/Caches/Homebrew` and `~/Library/Logs/Homebrew` with the real install. A `brew cleanup --prune=all` in a sandbox without these variables once deleted 450 real cache and log files. Read a dry run before you run the real command, and never chain them.

### The integration tests

```sh
HOMEBREW_SUBSTITUTE_TEST_SANDBOX=1 <sandbox>/bin/brew ruby test/integration.rb
```

- Set `HOMEBREW_CACHE` and `HOMEBREW_LOGS` first (see above). The script refuses to run with the default values.
- The script builds its own tap `substitute-test/probe` and links this repo as `substitute-test/substitute`. It keeps its trust entries in a scratch `XDG_CONFIG_HOME`, and removes the taps and formulae at the end.
- Name the variables `HOMEBREW_...`. Brew drops other variables before it runs the script. `HOMEBREW_SUBSTITUTE_TEST_ONLY=<text>` runs only the scenarios whose name contains the text.
- `brew ruby` turns on developer mode, and the `brew substitute` list and `--refresh` read every stub in the prefix. A sandbox with stubs from older tests makes the scenarios fail. Use a fresh clone.
- Each scenario takes a snapshot of the test formulae in the prefix before a refused command and compares it afterward. Add a snapshot check to every new refusal.
- To run on Linux, use the `ghcr.io/homebrew/brew` Docker image. Mount this repo read-only, copy it to a new git repository inside the container, and run `brew ruby` on the copy. Docker cannot see files under `/private/tmp`.

### Set up for manual checks

1. Symlink this repo into the sandbox: `ln -s <this repo> <sandbox>/Library/Taps/<user>/homebrew-substitute`.
2. Trust the command: `./bin/brew trust --command <user>/substitute/substitute`. Trust is global to the user, not per prefix.
3. Create a throwaway tap with three formulae that install from a local `file://` tarball, and tap it with `./bin/brew tap <user>/probe <path>`. Run `./bin/brew trust <user>/probe`.
   - `foo`: the original.
   - `foo-full`: the substitute, with `keg_only :versioned_formula`. A keg-only versioned formula loads `foo` when it installs, so `foo` must be loadable.
   - `foo-user`: depends on `foo`.
   - `foo-user2`: a second dependent of `foo`. The pin-error test installs it.
4. For the library check, make a second set whose original installs a real dylib (`cc -dynamiclib`, with `-install_name` set to `opt_lib/...`). Make the dependent link against it, and make the substitute ship no library. The library check must then refuse.

### What to run by hand

The script covers the happy path, the remove modes, the refusals, the library check, stale stubs, `--refresh`, and `--refresh` before the upgrade. These checks stay manual:

- Rollback: the library check now stops the dylib set, so force the failure. Temporarily make `linkage_ok?` return `false`. Run the swap once with a real original, and once with none (`--remove --no-install` first, and unlink the substitute). Run it a third time with the `opt` link of the substitute moved away, so that `Substitution.create` raises. For the failed reinstall of `--remove`, move the source tarball of the original away. Snapshot before and after each run. The snapshots must be identical. Remove the temporary edit and the moved files afterward.
- Ctrl-C: send SIGINT to the process group before the uninstall finishes, during the linkage test, and during the reinstall of `--remove`. The first two must roll back and exit 130. The third must leave the substitute linked and print the install command.
- Exit codes: capture them from a file or a variable. A pipe through `grep` hides them.

### On the real install

- Ask first. The real swap uninstalls the real original.
- Do not run dependents to test them. Some are interactive. Use `otool -L` and `brew linkage --test`.
- Take a state snapshot first: the link targets in `bin`, the formulae that depend on the original, and the pins.
