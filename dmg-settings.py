# Layout of the Track Livery installer window, read by dmgbuild
# (https://github.com/dmgbuild/dmgbuild, `pip install dmgbuild`).
# dmgbuild writes the window layout itself, so Finder is never asked to arrange it.
# The background is assets/dmg_background.png, with a sharp @2x copy beside it,
# both drawn from assets/dmg_background.svg.
app = defines["app"]  # noqa: F821  (passed in by make-dmg.sh with -D app=...)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"
background = "assets/dmg_background.png"
format = "UDZO"
# 640 x 448 picture; the extra height keeps the bottom line clear of Finder's path bar,
# which people may have switched on for every window.
window_rect = ((200, 120), (640, 508))
icon_size = 128
text_size = 13
icon_locations = {"TrackLivery.app": (160, 228), "Applications": (480, 228)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
