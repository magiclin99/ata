# dmgbuild settings for the release disk image's Finder layout, used by scripts/make-dmg-layout.sh to write
# Resources/dmg/DS_Store (volume name "ATA"). Releases reuse that file; see scripts/release.sh.
# Window and icon positions match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]                      # noqa: F821 (provided by dmgbuild)
background = defines["background"]        # noqa: F821
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 200), "Applications": (470, 200)}
window_rect = ((200, 160), (640, 420))
icon_size = 112
text_size = 13
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
hide_extension = [os.path.basename(app)]
