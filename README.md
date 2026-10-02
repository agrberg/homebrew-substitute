# homebrew-substitute

`brew substitute` lets you choose which installed formula satisfies a dependency. It is meant for `-full` variants. It affects your machine only, and you are responsible for the result.

Example: you use `ffmpeg-full`, and many formulae declare `depends_on "ffmpeg"`. Without this tap, brew installs the slim `ffmpeg` as well. With this tap, you run `brew substitute ffmpeg-full`. Brew then treats `ffmpeg` as installed, and `ffmpeg-full` serves every dependent.

## Install

Tap the repository. Then trust the command. Homebrew runs a tap command only after you trust it.

```sh
brew tap agrberg/substitute
brew trust --command agrberg/substitute/substitute
```

The tap needs a current Homebrew. It was tested with Homebrew 7.0.8. See the Homebrew pages on [taps](https://docs.brew.sh/Taps), [external commands](https://docs.brew.sh/External-Commands) and [tap trust](https://docs.brew.sh/Tap-Trust).

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

| Command | What it does |
|---|---|
| `brew substitute ffmpeg-full` | Substitute `ffmpeg-full` for `ffmpeg`. |
| `brew substitute node@22 --for=node` | Name the original yourself. |
| `brew substitute` | List the substitutions and their status. |
| `brew substitute --refresh` | Re-point stale substitutions after the original gets a new version. |
| `brew substitute --remove ffmpeg` | Remove the substitution and install the real `ffmpeg` again. |

With `--remove`, name the original (`ffmpeg`), not the substitute. Add `--dry-run` to any command to preview it. [ARCHITECTURE.md](ARCHITECTURE.md) lists every option, status and exit code.

## After `brew upgrade`

Run `brew upgrade` first. Then run `brew substitute --refresh`. A refresh is necessary only when the original formula gets a new version or revision.

Do not run `brew unpin` on the original. Brew can print `You must brew unpin ffmpeg` when you install a dependent while a substitution is stale. That error means that you must run `brew substitute --refresh`. If you unpin the original, brew installs the real original over the stub.

## Limits

This is an unsupported change to your own machine. Homebrew maintainers declined to support it in core:

- [Homebrew/brew#23368](https://github.com/Homebrew/brew/issues/23368): a request for `ffmpeg-full` to satisfy `ffmpeg`, closed as not planned.
- [Discussion #7032](https://github.com/orgs/Homebrew/discussions/7032): a request for a `provides` setting, closed.
- [Homebrew/brew#5615](https://github.com/Homebrew/brew/issues/5615): the same request in 2019.

Do not report problems that this tap causes to Homebrew or to formula maintainers. To return to a normal install, run `brew substitute --remove <original>`.

The substitute and the original must have the same version. The library check cannot see a library that a program opens at run time by path. The tool was tested on macOS only, and it handles formulae, not casks. The project has no automated tests.

## More

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the command works, why it works that way, and what was tested.

## License

[MIT](LICENSE).
