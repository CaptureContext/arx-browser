# Files

John Sundell's [Files](https://github.com/JohnSundell/Files) (MIT, notice kept in the source), copied from fxcodex's `FXCodexFS` with its typed throws.

One local change: `File.write` is atomic and writes through symbolic links. Arx rewrites configuration files that belong to other tools, so a crash mid-write must not truncate them, and a linked file must stay linked.
