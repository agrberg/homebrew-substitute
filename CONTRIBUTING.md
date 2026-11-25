# Contributing

Read [ARCHITECTURE.md](ARCHITECTURE.md) before you change behavior. Run `./bin/style` before you push. The script runs the brew of the prefix that holds this checkout, so keep the checkout at `<sandbox>/Library/Taps/agrberg/homebrew-substitute`. The integration tests below run in a separate Homebrew prefix.

## Test procedure

`test/integration.rb` runs most checks. A few checks (rollback and Ctrl-C) are manual. Run both in a separate Homebrew prefix. Do not test on the user's real install without their approval.

## The sandbox

A checkout of Homebrew/brew is a complete prefix. Running `./bin/brew` inside it uses `Cellar`, `opt`, `var` and `Library/Taps` in that checkout, and git ignores them. Clone Homebrew/brew to make one. Do not put it under `/tmp`: brew refuses a prefix in its temporary directory.

Before any command in the sandbox, set the cache and log directories to a scratch location:

```sh
export HOMEBREW_CACHE=<scratch>/cache HOMEBREW_LOGS=<scratch>/logs HOMEBREW_NO_AUTO_UPDATE=1
```

The sandbox shares `~/Library/Caches/Homebrew` and `~/Library/Logs/Homebrew` with the real install. A `brew cleanup --prune=all` in a sandbox without these variables once deleted 450 real cache and log files. Read a dry run before you run the real command, and never chain them.

## The integration tests

```sh
./bin/test
```

- `./bin/test` runs the brew of the prefix that holds this checkout. It sets `HOMEBREW_SUBSTITUTE_TEST_SANDBOX`, `HOMEBREW_NO_AUTO_UPDATE`, and `HOMEBREW_CACHE` and `HOMEBREW_LOGS` in `<sandbox>-scratch`. It refuses a default Homebrew prefix.
- To run without the wrapper, set `HOMEBREW_SUBSTITUTE_TEST_SANDBOX=1`, `HOMEBREW_CACHE` and `HOMEBREW_LOGS` (see above), and run `<sandbox>/bin/brew ruby test/integration.rb`. The script refuses to run with the default values.
- The script builds its own tap `substitute-test/probe` and links this repo as `substitute-test/substitute`. It keeps its trust entries in a scratch `XDG_CONFIG_HOME`, and removes the taps and formulae at the end.
- Name the variables `HOMEBREW_...`. Brew drops other variables before it runs the script. `HOMEBREW_SUBSTITUTE_TEST_ONLY=<text>` runs only the scenarios whose name contains the text.
- `brew ruby` turns on developer mode, and the `brew substitute` list and `--refresh` read every stub in the prefix. A sandbox with stubs from older tests makes the scenarios fail. Use a fresh clone.
- Each scenario takes a snapshot of the test formulae in the prefix before a refused command and compares it afterward. Add a snapshot check to every new refusal.
- To run on Linux, use the `ghcr.io/homebrew/brew` Docker image. Mount this repo read-only, copy it to a new git repository inside the container, and run `brew ruby` on the copy. Docker cannot see files under `/private/tmp`.

## Set up for manual checks

1. Clone this repo into the sandbox at `<sandbox>/Library/Taps/agrberg/homebrew-substitute`. Brew then finds it as the tap `agrberg/substitute`. Use `agrberg` for `<user>` in the steps below.
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
