# Arx for Raycast

A local Raycast extension for Arx (DEV-909): **Search Tabs** (reads Arx's AppleScript dictionary
and shows a tab with `show tab`), **Open in Space** and **New Little Arx** (open `arx://open` and
`arx://little` links). It needs an interactive Arx; a headless run lists no tabs and ignores
the links.

Not published to the Raycast Store: publishing is Max's decision. To try it, run
`npm install && npm run dev` here with Raycast installed, then allow Raycast to control Arx when
macOS asks. Add an `assets/icon.png` (512×512) before `ray build`; the Store requires one.

It has no licence field yet. The Store needs one; Arx itself is GPL-3.0, and the extension's licence is chosen when it's published.
