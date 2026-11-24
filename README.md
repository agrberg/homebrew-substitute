# homebrew-substitute

[![CI](https://github.com/agrberg/homebrew-substitute/actions/workflows/ci.yml/badge.svg)](https://github.com/agrberg/homebrew-substitute/actions/workflows/ci.yml)

`brew substitute` lets you choose which installed formula satisfies a dependency. It is conventionally meant for `-full` variants and can work with any substitution.

**IMPORTANT: Homebrew has declined creating this feature more than once. This affects your machine only, and you are responsible for the result. See [Limits](#limits).**

Example: you use `ffmpeg-full`, and many formulae declare `depends_on "ffmpeg"`. Without this tap, brew installs the slim `ffmpeg` as well. With this tap, you run `brew substitute ffmpeg-full`. Brew then treats `ffmpeg` as installed, and `ffmpeg-full` serves every dependent.

The tap works on macOS and Linux.

## Install

Tap the repository. Then trust the command. Homebrew runs a tap command only after you trust it.

```sh
brew tap agrberg/substitute
brew trust --command agrberg/substitute/substitute
```

The tap needs a current Homebrew. The command uses Homebrew internals that can change without notice, so CI runs the tests on macOS and Linux against the current Homebrew for every pull request and every week. See the Homebrew pages on [taps](https://docs.brew.sh/Taps), [external commands](https://docs.brew.sh/External-Commands) and [tap trust](https://docs.brew.sh/Tap-Trust).

## Use

Substitute `ffmpeg-full` for `ffmpeg`:

```sh
brew substitute ffmpeg-full
```

The command infers the original by removing `-full` from the name. If the name does not end in `-full`, pass the original with `--for=<original>`.

Preview the steps first. This changes nothing:

```console
$ brew substitute ffmpeg-full --dry-run
==> Would uninstall ffmpeg with --ignore-dependencies
==> Would create a stub keg for ffmpeg 9.0.2 that points to ffmpeg-full
==> Would pin ffmpeg
==> Would link ffmpeg-full
==> Would run `brew linkage --test` on the dependents of ffmpeg
```

Before the command removes the original, it checks that the substitute has every library that an installed dependent loads from the original. If the check or the final test fails, the command restores the original and stops with an error.

| Command                              | What it does                                                        |
| ------------------------------------ | ------------------------------------------------------------------- |
| `brew substitute ffmpeg-full`        | Substitute `ffmpeg-full` for `ffmpeg`.                              |
| `brew substitute node@22 --for=node` | Name the original yourself.                                         |
| `brew substitute`                    | List the substitutions and their status.                            |
| `brew substitute --refresh`          | Re-point stale substitutions after the original gets a new version. |
| `brew substitute --remove ffmpeg`    | Remove the substitution and install the real `ffmpeg` again.        |

With `--remove`, name the original (`ffmpeg`), not the substitute. Add `--dry-run` to any command to preview it. [ARCHITECTURE.md](ARCHITECTURE.md) lists every option, status and exit code.

## Updating / After `brew upgrade`

Run `brew upgrade` first. Then run `brew substitute --refresh`. A refresh is necessary only when the original formula gets a new version or revision.

Do not run `brew unpin` on the original. Brew can print `You must brew unpin ffmpeg` when you install a dependent while a substitution is stale. That error means that you must run `brew substitute --refresh`. If you unpin the original, brew installs the real original over the stub.

## Limits

This is an unsupported change to your own machine. Homebrew maintainers declined to support it in core:

- [Homebrew/brew#23368](https://github.com/Homebrew/brew/issues/23368): a request for `ffmpeg-full` to satisfy `ffmpeg`, closed as not planned.
- [Discussion #7032](https://github.com/orgs/Homebrew/discussions/7032): a request for a `provides` setting, closed.
- [Homebrew/brew#5615](https://github.com/Homebrew/brew/issues/5615): the same request in 2019.

Do not report problems that this tap causes to Homebrew or to formula maintainers. To return to a normal install, run `brew substitute --remove <original>`. Do report non-formula problems with this tap here.

The substitute and the original must have the same version. The library check cannot see a library that a program opens at run time by path. The tool handles formulae, not casks.

## Uninstall

Remove every substitution first. Then untap. If you untap first, the stubs and pins stay in your Cellar, and the `brew substitute --remove` command is gone.

```sh
brew substitute --remove <original>
brew untap agrberg/substitute
```

Run the first command once for each original that `brew substitute` lists.

## Develop

The integration tests install and uninstall formulae. Run them only in a throwaway Homebrew prefix. The steps to make one are in [CONTRIBUTING.md](CONTRIBUTING.md). CI runs the same tests on a macOS runner and a Linux runner.

```sh
./bin/style
HOMEBREW_SUBSTITUTE_TEST_SANDBOX=1 HOMEBREW_CACHE=<scratch>/cache HOMEBREW_LOGS=<scratch>/logs \
  <sandbox>/bin/brew ruby test/integration.rb
```

## More

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the command works, why it works that way, and what was tested.

## License

[MIT](LICENSE).
