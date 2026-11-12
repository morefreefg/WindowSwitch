#!/usr/bin/env python3
"""Write the .DS_Store that gives a mounted DMG its drag-to-install window layout.

Finder stores icon positions and the background picture in .DS_Store. Driving Finder
over AppleScript needs a GUI session and Apple event permission, so this writes the
file directly instead and works the same on a headless builder.
"""
import pathlib
import sys

from ds_store import DSStore
import mac_alias

WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (600, 428)  # 含标题栏；内容区约 600x400，与背景图一致
ICON_SIZE = 80.0
POSITIONS = {'WindowSwitch.app': (150, 190), 'Applications': (450, 190)}

volume = pathlib.Path(sys.argv[1])
background = volume / '.background' / 'background.tiff'
if not background.is_file():
    sys.exit(f'Missing the background picture: {background}')

icon_view = {
    'viewOptionsVersion': 1,
    'backgroundType': 2,
    'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
    'backgroundImageAlias': mac_alias.Alias.for_file(str(background)).to_bytes(),
    'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
    'arrangeBy': 'none', 'showIconPreview': True, 'showItemInfo': False,
    'labelOnBottom': True, 'textSize': 12.0, 'iconSize': ICON_SIZE,
    'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
}
window = {
    'WindowBounds': '{{%d, %d}, {%d, %d}}' % (*WINDOW_ORIGIN, *WINDOW_SIZE),
    'ShowStatusBar': False, 'ShowTabView': False, 'ShowPathbar': False,
    'ShowSidebar': False, 'ShowToolbar': False,
    'ContainerShowSidebar': False, 'PreviewPaneVisibility': False, 'SidebarWidth': 0,
}

with DSStore.open(str(volume / '.DS_Store'), 'w+') as store:
    store['.']['vSrn'] = ('long', 1)
    store['.']['ICVO'] = ('bool', True)
    store['.']['icvl'] = ('type', 'icnv')
    store['.']['icvp'] = icon_view
    store['.']['bwsp'] = window
    for name, position in POSITIONS.items():
        if not (volume / name).exists():
            sys.exit(f'Missing the item to position: {name}')
        store[name]['Iloc'] = position
print('Wrote the DMG window layout.')
