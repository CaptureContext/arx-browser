# Engine branding

Arx's logo for the engine (DEV-1100), in place of Helium's. `Scripts/engine/branding_overlay.py` puts each file at Helium's logo destinations in the prepared Chromium tree. Preparation stops if any of them is Helium's again, and so does the engine build if the built framework bundles Helium's logo or names Helium in its English strings.

- `product_logo_<size>.png`: Arx's app icon in its dark rendition (AppUI's `appIcon.dark`: a white mark on a black tile). Among other uses, it's the artwork macOS Now Playing shows for a page without Media Session artwork (`IDR_PRODUCT_LOGO_256`).
- `product_logo_white_<size>.png` and `product_logo_22_mono.png`: the Arx mark in white, and in black as a template.
- `product_logo.svg` and `arx_mark.icon`: the Arx mark as SVG and in Chromium's vector icon format.
- `app.icns` and `Assets.car`: the helpers' icon, which the Alerts helpers show, compiled by `actool` from `Containers/macOS/AppIcon.icon` for Chromium's deployment target (macOS 13). `Assets.car` carries the light and dark appearances, so the helpers follow the system; `app.icns` is the light one.

All of them are rendered from AppUI's dark app icon, `ArxLogo`'s path (three blades in a 700 × 674 space) and the app's Icon Composer icon by `swift Scripts/engine/render_branding.swift`. Render them again when Arx's icon or mark changes.
