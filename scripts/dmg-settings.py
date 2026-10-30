"""Installer positions, persisted directly as Finder metadata by dmgbuild."""
import os

files = [os.environ['MAGDOT_DMG_APP']]
symlinks = {'Applications': '/Applications'}
background = os.environ['MAGDOT_DMG_BACKGROUND']
format = 'UDZO'
filesystem = 'HFS+'
window_rect = ((180, 140), (600, 388))
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 88
text_size = 13
label_pos = 'bottom'
icon_locations = {'MagDot.app': (180, 180), 'Applications': (420, 180)}
