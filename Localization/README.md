# Localization

Configuration for Arx's translations (DEV-1291). The rules and commands are in [`.agents/LOCALIZATION.md`](../.agents/LOCALIZATION.md).

- `languages.json`: the source language, the languages Arx ships (`shipped`, which `make check` holds to a complete translation and which `.xcodegen/macOS.yml`'s `CFBundleLocalizations` must list), and the ones being translated (`planned`).
- `sources.json`: written by `make localization-import`, never by hand. For every imported translation, a short hash of the English it was made from, so `make localization-check` can tell when the English has changed since.
