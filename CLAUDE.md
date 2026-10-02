# CLAUDE.md

Working notes for AI coding sessions in this repo.

## What this is

A Homebrew tap with one Ruby external command, `brew substitute`. Read [ARCHITECTURE.md](ARCHITECTURE.md) before you change behavior. [README.md](README.md) is the user guide.

## Layout

- `cmd/substitute.rb`: the command and all its modes. The file must stay executable (mode 755) in git.
- `lib/substitution.rb`: the stub keg logic that both commands share.

## Rules for changes

- Keep every mode in `cmd/substitute.rb`. Brew checks trust for each command file, so a second file means that every user must run a second `brew trust --command`.
- Keep the stub keg layout in ARCHITECTURE.md. Two simpler layouts fail, and one of them deletes the substitute on `brew uninstall`.
- Run every read-only check before any step that changes state.
- Give each new step that changes state a rollback, and restore link states with `Substitution.reinstall_original`.
- `Keg#path` is protected. Use `keg.to_s`.
- Call `brew` through `Substitution.brew`. It uses `SystemCommand.safe_system`. Plain `safe_system` is not available in a module.
- Write `typed: strict` Ruby with Sorbet `sig` blocks, in the style of Homebrew's own commands.
- When behavior changes, update the verification record in ARCHITECTURE.md and the examples in README.md.
- Commit with explicit paths. Do not use `git add -A`.
- Work on a branch and merge through a pull request. Do not commit to `main`. Name branches `ar/<short-description>` in lowercase.

## Lint

```sh
brew style cmd/substitute.rb lib/substitution.rb
```

`brew style --fix` corrects most layout offenses. It also reflows lines, so read the result. `brew typecheck` does not cover taps.

## Test procedure

The repo has no automated tests. Testing is manual, in a separate Homebrew prefix. Do not test on the user's real install without their approval.

### The sandbox

A checkout of Homebrew/brew is a complete prefix. Running `./bin/brew` inside it uses `Cellar`, `opt`, `var` and `Library/Taps` in that checkout, and git ignores them. Clone Homebrew/brew to make one.

Before any command in the sandbox, set the cache and log directories to a scratch location:

```sh
export HOMEBREW_CACHE=<scratch>/cache HOMEBREW_LOGS=<scratch>/logs HOMEBREW_NO_AUTO_UPDATE=1
```

The sandbox shares `~/Library/Caches/Homebrew` and `~/Library/Logs/Homebrew` with the real install. A `brew cleanup --prune=all` in a sandbox without these variables once deleted 450 real cache and log files. Read a dry run before you run the real command, and never chain them.

### Set up

1. Symlink this repo into the sandbox: `ln -s <this repo> <sandbox>/Library/Taps/<user>/homebrew-substitute`.
2. Trust the command: `./bin/brew trust --command <user>/substitute/substitute`. Trust is global to the user, not per prefix.
3. Create a throwaway tap with three formulae that install from a local `file://` tarball, and tap it with `./bin/brew tap <user>/probe <path>`. Run `./bin/brew trust <user>/probe`.
   - `foo`: the original.
   - `foo-full`: the substitute, with `keg_only :versioned_formula`. A keg-only versioned formula loads `foo` when it installs, so `foo` must be loadable.
   - `foo-user`: depends on `foo`.
   - `foo-user2`: a second dependent of `foo`. The pin-error test installs it.
4. For the library check, make a second set whose original installs a real dylib (`cc -dynamiclib`, with `-install_name` set to `opt_lib/...`). Make the dependent link against it, and make the substitute ship no library. The library check must then refuse.

### What to run

- Happy path: `brew substitute foo-full`, install a new dependent, check that `foo` is not installed, then `brew substitute --remove foo`.
- Remove modes: `--remove --dry-run` must change nothing. `--remove --no-install` must remove only the stub and the pin. The default must reinstall the original and restore the link states. Also try the refused combinations (`--remove` with `--force`, `--for` or `--refresh`, and `--no-install` without `--remove`).
- Library check: run the dylib set with `--dry-run` (must print `Would fail` and exit 1), then without it, then with `--force`. Each must refuse before the uninstall. Snapshot kegs, pins and prefix links before and after. The snapshots must be identical, except for the install of the substitute.
- Rollback: the library check now stops the dylib set, so force the failure. Temporarily make `linkage_ok?` return `false`. Run the swap once with a real original, and once with none (`--remove --no-install` first, and unlink the substitute). Run it a third time with the `opt` link of the substitute moved away, so that `Substitution.create` raises. For the failed reinstall of `--remove`, move the source tarball of the original away. Snapshot before and after each run. The snapshots must be identical. Remove the temporary edit and the moved files afterward.
- Refusals: a pinned original (`brew pin foo` first, with and without `--dry-run`), version mismatch, a name without `-full` and no `--for`, `--for` with two substitutes, a second substitute for one original. Each must leave the state unchanged.
- Stale and refresh: add `revision 1` to the original in the tap clone, then run `brew substitute`, `brew outdated` and `brew substitute --refresh`.
- Stale stub and a dependent: with the stub stale, install `foo-user2`. Brew must print the `brew unpin` error. Run `brew substitute --refresh`, then install again. The install must work.
- Refresh before upgrade: add `revision 1` to both formulae, and do not upgrade the substitute. `brew substitute` must show `stale`, and `--refresh` must refuse. Run `brew upgrade <substitute>`, then `--refresh`. A revision bump of the substitute alone must show `behind` until the upgrade.
- Exit codes: capture them from a file or a variable. A pipe through `grep` hides them.

### On the real install

- Ask first. The real swap uninstalls the real original.
- Do not run dependents to test them. Some are interactive. Use `otool -L` and `brew linkage --test`.
- Take a state snapshot first: the link targets in `bin`, the formulae that depend on the original, and the pins.
