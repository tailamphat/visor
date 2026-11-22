# Contributing to Visor

Thanks for helping. Visor is a native macOS notch app built with Swift Package Manager. The Command Line Tools are enough; Xcode is not required.

## Build and test

```sh
./scripts/bundle.sh --open   # build build/Visor.app and launch it
scripts/test.sh              # unit tests
```

Use `scripts/test.sh`, not plain `swift test`. It passes the Swift Testing macro plugin path, which incremental test builds otherwise lose with the Command Line Tools.

## How we work

- **Read first.** [docs/architecture.md](docs/architecture.md) has the module map, data flows and recipes for new features. [CLAUDE.md](CLAUDE.md) has the project rules, toolchain notes and how to test the UI through the debug socket without a mouse.
- **Test first.** Start a behaviour change with a failing test in `Tests/VisorCoreTests`. Put the logic in `VisorCore` so it can be tested without AppKit.
- **UI changes** start from a mockup and end with a screenshot of the real notch. Keep the header balanced around the camera (see CLAUDE.md).
- **Keep it fast.** Event-driven, off the main thread, ~0% CPU at idle.
- **Writing:** plain short sentences, no em dashes. Use a hyphen or a colon.
- **Fixtures** use `acme.ghe.com`, `octocat` and `/Users/me`. Never real employer names, work accounts, internal hosts or personal email addresses.

## Commits

[Conventional Commits](https://www.conventionalcommits.org): `type(scope): plain description`.

```
feat(usage): show Copilot premium requests
fix(music): keep the play state after a browser pause
perf(agents): publish the board only when it changes
docs(plugins): document visor.repos()
```

## Plugins

Writing a plugin doesn't need a change to Visor. See [docs/plugins.md](docs/plugins.md). Ideas for new plugin APIs are welcome as a "Plugin idea" issue.

## Security

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md).
