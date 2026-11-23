# dmgbuild settings for the Arx release disk image. Scripts/release.py passes the
# signed app as `-D app=<path>`; dmgbuild supplies `defines` when it runs this file.
import os.path

application = defines["app"]  # noqa: F821
name = os.path.basename(application)

format = "ULFO"
files = [application]
# No Applications shortcut: the design asks the person to double-click Arx, and the app
# moves itself to Applications on first launch (AppFeature's RelocationRetry).
symlinks = {}

# The Figma frame "Background (export @1x and @2x)" on the Dmg page, 600 x 380 points, with 52
# more points of its bottom colour added below. Finder's path bar and status bar are the
# person's own settings and take that much from the bottom of the window when both are on, so
# the extra strip is what they cover instead of the instruction line. dmgbuild
# finds dmg-background@2x.png beside it and writes a multi-resolution TIFF for Retina. The
# artwork has the wordmark and the instruction line baked in, so neither can be localized.
# Finder draws the app icon and its label on top. Scripts/release.py passes the file's path as
# `-D background=<path>`, since dmgbuild resolves paths against the working directory.
background = defines["background"]  # noqa: F821
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
# The window's frame: 28 points of title bar above the 600 x 432 artwork.
window_rect = ((200, 120), (600, 460))
icon_size = 128
text_size = 13
arrange_by = None
# The app icon's centre: the frame's 128-point slot at (236, 114).
# The background file is hidden; when Finder shows hidden files it sits below the window.
icon_locations = {
    name: (300, 178),
    ".background.tiff": (300, 700),
}
