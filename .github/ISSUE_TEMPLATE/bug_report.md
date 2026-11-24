---
name: Bug report
about: A problem with `brew substitute`
labels: bug
---

Report problems with this tap here. Do not report them to Homebrew or to formula maintainers. See [Limits](https://github.com/agrberg/homebrew-substitute#limits).

Run the command again with `--dry-run`. Then paste the output of these commands:

```sh
brew config
brew substitute
brew substitute <the command that failed> --dry-run
```

Describe what you expected and what happened. Include the full output of the failed command.
