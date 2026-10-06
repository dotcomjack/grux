# dmgbuild settings for Grux.dmg. Run: dmgbuild -s settings.py -D app=/path/Grux.app "Grux" Grux.dmg
import os
app = defines["app"]
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = None
icon_locations = {os.path.basename(app): (170, 200), "Applications": (470, 200)}
background = defines.get("background", "background.tiff")
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 128
text_size = 13
