# Architecture

This tap adds `brew substitute`. It makes Homebrew treat one installed formula (the substitute) as if it were another formula (the original). Dependents of the original then use the substitute. `brew substitute --remove` undoes the change.

Code links below point at [Homebrew/brew at commit 7f74c7bdd0](https://github.com/Homebrew/brew/tree/7f74c7bdd0969153a18bfa6fc9eb6518c113a035). Homebrew states that [Ruby external commands use internals that can change without notice](https://docs.brew.sh/External-Commands), so re-check these links when Homebrew changes.

## Command reference

| Option | Meaning |
|---|---|
| `--for=<original>` | The original formula. Valid with exactly one substitute. Required when the substitute name does not end in `-full`. |
| `-n`, `--dry-run` | Print the steps. Change nothing. |
| `--force` | Skip the version check, the check for an outdated substitute, and the dependency warning. It does not skip the library check. |
| `--refresh` | Re-point stale substitutions to the current version of the original. |
| `--remove` | Remove the substitution for each original and install the original again. Cannot combine with `--refresh`, `--for` or `--force`. |
| `--no-install` | Valid only with `--remove`. Do not install the original again. |

Other invocations:

- `brew substitute ffmpeg-full imagemagick-full` swaps each substitute in turn. A refusal on a later name leaves the earlier swaps in place.
- `brew substitute --remove ffmpeg --no-install` removes only the stub and the pin.
- `brew substitute --remove <a> <b>` removes each original in turn. If `<b>` is not substituted, the command exits with an error after it removed `<a>`.

### Status

`brew substitute` with no arguments prints one line for each substitution: `<original> -> <substitute> (<version>, <status>)`. The format can change. The status is one of:

- `ok`: the stub matches the current version of the original.
- `stale`: the original has a newer version than the stub. `brew outdated` lists it too. Run `brew substitute --refresh`.
- `behind`: the formula of the substitute names a newer version than the installed substitute. Run `brew upgrade <substitute>`. If the original also has a new version, the status is `stale`, and `brew substitute --refresh` refuses until you upgrade the substitute.
- `unknown`: brew cannot load the original or the substitute, for example because its tap is gone. `brew substitute --refresh` skips it. `brew substitute --remove` needs the original formula to load.
- `dangling`: the substitute is no longer installed. Run `brew substitute --remove <original>` or reinstall the substitute.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, or nothing to do. A swap of a pair that is already substituted prints a message and exits 0. |
| 1 | The command refused or failed. |
| 130 | Ctrl-C. The command rolled back first if it had started to change state. |

### Checks

- The substitute and the original must have the same version. A different version can change library names. `--force` skips this check.
- The command warns if the substitute does not depend on everything that the original depends on.
- Other formulae can load libraries by path, such as `/opt/homebrew/opt/ffmpeg/lib/libavcodec.dylib`. These work only if the substitute has the same libraries. The library check and the linkage test find most missing libraries.

## Terms

| Term | Meaning |
|---|---|
| Formula | A package recipe, such as `ffmpeg`. |
| Cellar | The directory `HOMEBREW_PREFIX/Cellar`. It holds every installed package. |
| Rack | The directory `Cellar/<name>`. It holds one keg per installed version. |
| Keg | The directory `Cellar/<name>/<version>`. It holds the files of one installed version. |
| Opt prefix | The symlink `HOMEBREW_PREFIX/opt/<name>`. It points at the keg that is current. Built software loads libraries through this path. |
| Pin | A symlink in `var/homebrew/pinned` that tells brew to leave a formula at one version. |
| Bottle | A prebuilt binary package. |
| Keg-only | A formula that brew installs but does not link into `bin`, `lib` and so on. `ffmpeg-full` is keg-only. |

## The constraint

An external command runs only when you call it. It cannot change how a later `brew install` resolves dependencies. So the command changes the files that brew reads.

Brew decides that a dependency is installed in [`Dependency#installed?`](https://github.com/Homebrew/brew/blob/7f74c7bdd0969153a18bfa6fc9eb6518c113a035/Library/Homebrew/dependency.rb#L70-L82). A dependency counts as installed when two things hold:

1. `opt/<original>` exists.
2. `Cellar/<original>/<current version>` is a non-empty directory ([`Formula#latest_version_installed?`](https://github.com/Homebrew/brew/blob/7f74c7bdd0969153a18bfa6fc9eb6518c113a035/Library/Homebrew/formula.rb#L986)).

The command creates exactly those two things, and the new files point at the substitute.

## The stub keg

```text
Cellar/ffmpeg/9.0.2/                 a real directory
  .substituted-by -> ../../../opt/ffmpeg-full
  bin             -> ../../../opt/ffmpeg-full/bin
  lib             -> ../../../opt/ffmpeg-full/lib
  include         -> ../../../opt/ffmpeg-full/include
  ...                                one symlink per entry in the substitute keg
opt/ffmpeg -> ../Cellar/ffmpeg/9.0.2
```

Rules for the layout:

- The stub is a real directory. Brew accepts it as a keg.
- Every entry goes through `opt/<substitute>`. The stub stays correct when the substitute upgrades, because the opt prefix of the substitute moves with it.
- The stub skips `INSTALL_RECEIPT.json`, `sbom.spdx.json` and `.brew`. A receipt would make the stub claim the substitute's identity.
- `.substituted-by` marks the stub. It names the substitute. All detection reads this link, so the tap keeps no state file.
- `opt/<original>` is a normal opt link to the stub, created with [`Keg#optlink`](https://github.com/Homebrew/brew/blob/7f74c7bdd0969153a18bfa6fc9eb6518c113a035/Library/Homebrew/keg.rb#L640). Built software that loads `opt/ffmpeg/lib/libavcodec.dylib` reaches the substitute's library through the stub.

### Layouts that fail

Both layouts were tested.

| Layout | Result |
|---|---|
| `Cellar/<original>/<version>` as a symlink to `opt/<substitute>` | Brew fails with `opt/<substitute> is not a valid keg`. |
| `opt/<original>` as a symlink to the substitute's real keg | `brew uninstall <original>` resolves the name through `opt/<original>` and deletes the real substitute keg. |

## Components

| File | Role |
|---|---|
| `lib/substitution.rb` | Stub creation, removal, detection and status. Helpers to call `brew` and to reinstall the original. |
| `cmd/substitute.rb` | `brew substitute`: argument handling, checks, the swap sequence, `--refresh`, `--remove` and listing. |

One command file holds every mode. Brew checks tap trust for each command file, so one file means that the user runs one `brew trust --command`.

`Substitution::Stub` is a value object with the original name, the substitute name, the stub version and the stub path. `Substitution.all` finds every stub by scanning the Cellar for a `.substituted-by` symlink.

## The swap sequence

For each substitute, `brew substitute` does these steps:

1. Resolve the original. The name is the substitute name without `-full`, or the value of `--for`.
2. Refuse if the original is the substitute, or if another substitute already serves the original.
3. Refuse if the original is pinned. `brew uninstall` exits 0 for a pinned formula and removes nothing, so the swap would go on with the real keg in place. Refuse if the versions differ, or if the installed substitute is older than its formula. Warn if the substitute lacks a dependency of the original. `--force` skips all three. With `--dry-run`, print the plan, check the libraries if the substitute is installed, and stop here.
4. Record which real original kegs exist, and the link state of the original and the substitute.
5. Install the substitute if it is missing.
6. Check the libraries (read-only). Refuse if a dependent of the original loads a library through `opt/<original>` that does not exist under `opt/<substitute>`. `--force` does not skip this check.
7. Uninstall the real original with `--ignore-dependencies`. If a real keg of the original remains, raise an error, so that the rollback runs.
8. Create the stub, link `opt/<original>` to it, and pin the original.
9. Link the substitute with `brew link --force`. A failure here prints a warning and continues.
10. Run `brew linkage --test` on every installed dependent of the original. This step is the safety net for the library check. Homebrew `master` since 23 Nov 2026 (commit eb09617, after the 7.0.16 release) fails the test for an "undeclared dependency", and a dependent that links the library of its original now links the substitute. CI installs Homebrew from `master`, so CI sees this first. The command accepts that one finding, and only when the substitute is the only entry listed, the exit status is 1, and the output has no `Error:` line. Older releases do not fail the test, so the command works on both.
11. If the linkage test fails, or if step 7, 8 or 10 raises an error or receives Ctrl-C, roll back. A failure in step 9 prints a warning and does not roll back. Remove the stub and the pin. Reinstall the original, or, if the original was not installed, restore the link state of the substitute. Then exit with an error.

Steps 1 to 6 change nothing except the install in step 5. A refusal in step 6 leaves the original in place and the substitute installed.

### The library check

The stub cannot exist beside the real original, because both use `Cellar/<original>/<version>` and `opt/<original>`. The test of the stub therefore runs after the uninstall in step 7. A failed test costs a network reinstall of the original. The library check in step 6 avoids that cost.

`Substitution.missing_libraries` reads the library names of every Mach-O or ELF file in each installed dependent, through `Keg#binary_executable_or_library_files`. It keeps each library name under `opt/<original>/` or `Cellar/<original>/`, maps the name to the same path under `opt/<substitute>`, and reports the paths that do not exist. The dependents come from `Formula#runtime_installed_formula_dependents`. `brew uses --installed` calls the same method.

The check does not see a library that a program opens at run time by path, or an extension that a script language loads. Brew resolves each library name to a file that exists, and a name such as `@rpath/...` resolves to nothing. The check works in `swap`, where the real original is still installed. In `--refresh`, `opt/<original>` is the stub, so a library that the substitute lacks may not resolve, and the check can pass. On Linux, a dependent names a library such as `libsublib.so`, and brew resolves the name through the runpath of the file to `opt/<original>/lib`, so the check works there too.

`--refresh` runs the version, `behind` and library checks for every stale stub before it changes any stub. One refusal leaves all stubs as they were.

### Link state

The substitute and the original install the same files into the prefix, so they cannot be linked at the same time. `Substitution.reinstall_original` unlinks the substitute, installs the original, and then restores the link states that the caller recorded.

- On rollback, the caller recorded the states before step 5.
- If the reinstall of the original fails, `reinstall_original` links the substitute again, prints the command to install the original, and raises the error of brew.
- On `--remove`, the original is left unlinked if the substitute is linked. Otherwise the original is linked.

### The pin

The pin has three jobs:

1. `brew upgrade` skips the original, so brew does not install the real original over the stub.
2. `brew uninstall <original>` refuses with `<original> is pinned`.
3. `brew outdated` does not list a current, unlinked keg. [`Formula#outdated_kegs`](https://github.com/Homebrew/brew/blob/7f74c7bdd0969153a18bfa6fc9eb6518c113a035/Library/Homebrew/formula.rb#L2068) treats an unlinked current keg as outdated unless the formula is pinned or the keg is optlinked. The stub is optlinked, so this job is a second layer of safety.

The pin has one side effect. A stale stub makes brew refuse to install a dependent that needs the current version. Brew prints ``You must `brew unpin <original>` as installing <dependent> requires the latest version of pinned dependencies`` ([`FormulaInstaller#check_install_sanity`](https://github.com/Homebrew/brew/blob/7f74c7bdd0969153a18bfa6fc9eb6518c113a035/Library/Homebrew/formula_installer.rb#L509)). The error does not mention this tap. The README tells the user to run `brew substitute --refresh` and not to unpin.

## Staleness and refresh

The stub directory name is the version of the original at creation time. When the original gets a newer version, the stub no longer matches, and `brew substitute` reports `stale`. `brew outdated` also lists the original.

The version check compares formula files. The stub points at the installed substitute, which can be older than its formula between `brew update` and `brew upgrade`. In that state the stub would name a version that the substitute does not have. `Substitution.behind?` detects it. `brew substitute` lists such a stub as `behind`, and `swap` and `--refresh` refuse until the user runs `brew upgrade <substitute>`.

`brew substitute --refresh` checks every stale stub first (the versions, the installed substitute, and the libraries). Then it runs, for each stale stub: remove the old stub (this also unpins), create a new stub at the current version, and pin. Brew has no hook that runs after an upgrade, so the user runs this command.

## Removal

`Substitution.remove` unpins the original and calls [`Keg#uninstall`](https://github.com/Homebrew/brew/blob/7f74c7bdd0969153a18bfa6fc9eb6518c113a035/Library/Homebrew/keg.rb#L327) on the stub. That method removes the stub directory with `FileUtils.rm_r`, which deletes symlinks and does not follow them. The substitute's files stay intact.

`brew substitute --remove <original>` runs these steps for each original:

1. Refuse if no stub exists for the original.
2. With `--dry-run`, print the plan and stop.
3. Remove the stub and the pin.
4. Unless `--no-install` is set, reinstall the original and restore the link states.

## Verification record

`test/integration.rb` runs the checks marked "automated" in a separate Homebrew prefix with throwaway source-built formulae. CI runs it on macOS and Linux. The other checks ran by hand in such a prefix, and on one real install.

| Check | Result |
|---|---|
| Automated: the whole script, on macOS (a clone of Homebrew/brew) and on Linux (Homebrew 7.0.13 in Docker) | Every check passes on both. |
| Automated: `brew substitute` in a prefix that has no Cellar | Prints `No substitutions.` and exits 0. |
| Automated: the library check on Linux | A dependent that loads `libsublib.so` through `opt/<original>` makes the check refuse, with `--dry-run`, without it and with `--force`. The substitute with the library is accepted. |
| Automated: the parser of the `brew linkage --test` output | The substitute as the only undeclared dependency is accepted, also for two dependents. Another undeclared dependency, a second kind of finding, an `Error:` line (also with color codes) and output with no finding are refused. |
| Automated: the first developer command of a user (`homebrew.devcmdrun` unset, `HOMEBREW_DEVELOPER` unset) | The swap succeeds and the developer-mode notice of `brew linkage` stays out of the output. Without `HOMEBREW_DEV_CMD_RUN` for the child process, the notice made the swap roll back. |
| A fresh dependent installs without installing the original | Pass |
| `brew uninstall <original>` on the stub, unpinned | Removes only the stub. The substitute keeps all files. |
| `brew uninstall <original>` on the stub, pinned | Refused |
| `brew cleanup` and `brew autoremove` | The stub and the pin survive. |
| `brew list`, `leaves`, `missing`, `info`, `outdated` | Consistent with the stub as an installed original. |
| Substitute upgrade (revision bump) | The stub stays valid. |
| Original version bump | Status `stale`, then `--refresh` re-points the stub and the pin. |
| The substitute lacks a library that a dependent loads | The library check refuses before the uninstall, also with `--force`. `--dry-run` reports `Would fail` with the missing path. Kegs, pins and prefix links match the state before the command, except for the install of the substitute. |
| `--dry-run` when the substitute is not installed | A warning says that the library check cannot run. The exit code is 0. |
| Linkage test fails after the swap (forced failure) | The command rolls back. Kegs, pins and prefix links match the state before the command. This holds with a real original and without one. |
| `Substitution.create` raises after the uninstall (the `opt` link of the substitute is missing) | The command rolls back and reinstalls the original. The state matches the state before the command. |
| The reinstall of the original fails during `--remove` (the source is missing) | The substitute stays linked, the stub and the pin are gone, and a message gives the install command. |
| Original and substitute both get a new revision, and the substitute is not upgraded | Status `behind`. `--refresh` refuses and names `brew upgrade`. After the upgrade, `--refresh` re-points the stub. |
| Substitute-only revision bump | Status `behind` until `brew upgrade`, then `ok`. No refresh is necessary. |
| Stale stub, then install a dependent | Brew prints the `brew unpin` error. After `brew substitute --refresh`, the install works. |
| The original formula cannot load | Status `unknown`. `--refresh` skips the stub. |
| The substitute formula file is gone, and the substitute is installed | Status `ok`. Brew loads the formula from the `.brew` directory of the installed keg. |
| `--refresh`, the new substitute lacks a library (`--dry-run` and real run) | Refused with `Would fail` or `Cannot refresh` and the missing path. The state does not change. |
| `--refresh`, `Substitution.create` raises after the old stub is removed | The message gives `brew substitute <substitute> --for=<original>`. That command creates the stub again. |
| `Substitution.create` raises after the pin and the `opt` link exist | The stub, the pin and the `opt` link are gone. The state matches the state before the command. |
| The reinstall of the original fails in the rollback of `swap` | The stub and the pin are gone, the substitute stays linked, and a message gives the install command. |
| Library names in the `opt/<original>` form and the `Cellar/<original>/<version>` form | Both map to `opt/<substitute>`. A sibling prefix such as `opt/<original>-extra`, a bare keg path, and a system library map to nothing. |
| Ctrl-C (SIGINT to the process group) before the uninstall finishes, and during the linkage test | The command rolls back, prints the cause, and exits 130. The state matches the state before the command. |
| Ctrl-C during the reinstall of the original in `--remove` | The substitute stays linked, the stub is gone, and a message gives the install command. Exit code 130. |
| `--refresh` with two stale stubs, where the second substitute lacks a library | Refused. The first stub is not changed either. |
| Re-run of the same swap, and a second substitute for one original | The re-run prints a message and exits 0. The second substitute is refused. |
| Version mismatch, missing `--for`, `--for` with two substitutes, second substitute for one original | Each is refused with no state change. |
| The original is pinned (current version, or an older keg with `--force`), with and without `--dry-run` | Refused with `<original> is pinned`, exit 1. The state matches the state before the command. Before this check, the same input exited 0 and left the pin on the old keg, or failed on `File exists` and could leave symlinks in the real keg. |
| `--remove`: bad combinations (`--force`, `--for`, `--refresh`), no arguments, an original that is not substituted, `--no-install` without `--remove` | Each is refused with no state change. |
| `--remove --dry-run` | Prints the plan. The stub and the pin stay. |
| `--remove --no-install` | Removes only the stub and the pin. |
| `--remove` with the default reinstall | The real original is installed again. The substitute stays linked and the original stays unlinked. |
| Real install: `ffmpeg-full` for `ffmpeg` | Linkage test passed for the three installed dependents. The `ffmpeg-full` keg and link stayed intact. |
| Real install: `--dry-run` install of three bottled dependents that are not installed | The plan did not include `ffmpeg`. |

## Not covered

- A real bottle install of a new dependent. The sandbox cannot pour bottles.
- A full cycle on the real install in which the original and the substitute both get a new version.
- `brew doctor`.
- Automated tests of the rollback paths and of Ctrl-C. These ran by hand. The test procedure is in `CLAUDE.md`.
- Casks. The commands handle formulae only.
- A Homebrew older than the current one. The automated tests run on the current Homebrew only.
- A library that a program opens at run time by path. The library check reads only load commands.
- A dependent that was broken before the swap. The linkage test after the swap cannot tell this case from a swap failure.
