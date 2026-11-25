# Contributing

Read [ARCHITECTURE.md](ARCHITECTURE.md) before you change behavior. Run `./bin/style` before you push. Run `./bin/test` when you change behavior. Both scripts use the sandbox that holds this checkout (see below). They fail if the checkout is anywhere else.

## Test procedure

`test/integration.rb` runs most checks. A few checks (rollback and Ctrl-C) are manual. Run both in the sandbox. Do not test on the user's real install without their approval.

## The sandbox

A checkout of Homebrew/brew is a complete prefix. Running `./bin/brew` inside it uses `Cellar`, `opt`, `var` and `Library/Taps` in that checkout, and git ignores them. Do not put it under `/tmp`: brew refuses a prefix in its temporary directory. A prefix at this path is a [Tier 3 configuration](https://github.com/Homebrew/brew/blob/HEAD/docs/Support-Tiers.md#tier-3), so use it only to develop and test this tap.

This checkout must be a tap inside the sandbox. Brew then finds it as the tap `agrberg/substitute`. To make the sandbox, clone both repositories:

```sh
git clone https://github.com/Homebrew/brew <sandbox>
mkdir -p <sandbox>/Library/Taps/agrberg
git clone <url of this repository> <sandbox>/Library/Taps/agrberg/homebrew-substitute
```

Work from `<sandbox>/Library/Taps/agrberg/homebrew-substitute`. Use a branch there. Do not use a `git worktree` for code changes: `./bin/style` and `./bin/test` look for `bin/brew` in the sandbox at that path, so they fail in a worktree.

`./bin/test` keeps its cache and log directories in `<sandbox>/cache` and `<sandbox>/logs`, which git ignores, unless you already exported `HOMEBREW_CACHE` or `HOMEBREW_LOGS`. Before any other command in the sandbox, set the same variables:

```sh
export HOMEBREW_CACHE=<sandbox>/cache HOMEBREW_LOGS=<sandbox>/logs HOMEBREW_NO_AUTO_UPDATE=1
```

The sandbox shares `~/Library/Caches/Homebrew` and `~/Library/Logs/Homebrew` with the real install. A `brew cleanup --prune=all` in a sandbox without these variables once deleted 450 real cache and log files. Read a dry run before you run the real command, and never chain them.

### What the tests change in the sandbox

The tests change the prefix, so use a sandbox that holds nothing that you need.

- They install and uninstall formulae.
- They move `Cellar` aside for a short time, and change `homebrew.devcmdrun` in the `.git/config` of the sandbox.
- They tap `substitute-test/probe`, and link this checkout as the tap `substitute-test/substitute`. They keep the trust entries in a scratch `XDG_CONFIG_HOME`, and remove the taps and formulae at the end.
- Each run first untaps `substitute-test/probe`. Run one test run at a time in a sandbox. A second run breaks the first.
- The tests stop with an error if another tap provides a different `brew substitute`. Untap that tap.

## The integration tests

```sh
./bin/test
```

- `./bin/test` runs the brew of the prefix that holds this checkout. It sets `HOMEBREW_SUBSTITUTE_TEST_SANDBOX`, `HOMEBREW_NO_AUTO_UPDATE`, and `HOMEBREW_CACHE` and `HOMEBREW_LOGS` in the sandbox. It refuses a default Homebrew prefix.
- To run without the wrapper, set `HOMEBREW_SUBSTITUTE_TEST_SANDBOX=1`, `HOMEBREW_CACHE` and `HOMEBREW_LOGS` (see above), and run `<sandbox>/bin/brew ruby test/integration.rb`. The script refuses to run with the default values.
- Name the variables `HOMEBREW_...`. Brew drops other variables before it runs the script. `HOMEBREW_SUBSTITUTE_TEST_ONLY=<text>` runs only the scenarios whose name contains the text.
- `brew ruby` turns on developer mode, and the `brew substitute` list and `--refresh` read every stub in the prefix. A sandbox with stubs from older tests makes the scenarios fail. Use a fresh clone.
- Each scenario takes a snapshot of the test formulae in the prefix before a refused command and compares it afterward. Add a snapshot check to every new refusal.
- To run on Linux, use the `ghcr.io/homebrew/brew` Docker image. Mount this repo read-only, copy it to a new git repository inside the container, and run `brew ruby` on the copy. Docker cannot see files under `/private/tmp`.

## Set up for manual checks

1. Make the sandbox as described above. Use `agrberg` for `<user>` in the steps below.
2. Trust the command: `./bin/brew trust --command <user>/substitute/substitute`. Trust is global to the user, not per prefix.
3. Create a throwaway tap with three formulae that install from a local `file://` tarball, and tap it with `./bin/brew tap <user>/probe <path>`. Run `./bin/brew trust <user>/probe`.
   - `foo`: the original.
   - `foo-full`: the substitute, with `keg_only :versioned_formula`. A keg-only versioned formula loads `foo` when it installs, so `foo` must be loadable.
   - `foo-user`: depends on `foo`.
   - `foo-user2`: a second dependent of `foo`. The pin-error test installs it.
4. For the library check, make a second set whose original installs a real dylib (`cc -dynamiclib`, with `-install_name` set to `opt_lib/...`). Make the dependent link against it, and make the substitute ship no library. The library check must then refuse.

## What to run by hand

The script covers the happy path, the remove modes, the refusals, the library check, stale stubs, `--refresh`, and `--refresh` before the upgrade. These checks stay manual:

- Rollback: the library check now stops the dylib set, so force the failure. Temporarily make `linkage_ok?` return `false`. Run the swap once with a real original, and once with none (`--remove --no-install` first, and unlink the substitute). Run it a third time with the `opt` link of the substitute moved away, so that `Substitution.create` raises. For the failed reinstall of `--remove`, move the source tarball of the original away. Snapshot before and after each run. The snapshots must be identical. Remove the temporary edit and the moved files afterward.
- Ctrl-C: send SIGINT to the process group before the uninstall finishes, during the linkage test, and during the reinstall of `--remove`. The first two must roll back and exit 130. The third must leave the substitute linked and print the install command.
- Exit codes: capture them from a file or a variable. A pipe through `grep` hides them.

## On the real install

- Ask first. The real swap uninstalls the real original.
- Do not run dependents to test them. Some are interactive. Use `otool -L` and `brew linkage --test`.
- Take a state snapshot first: the link targets in `bin`, the formulae that depend on the original, and the pins.
