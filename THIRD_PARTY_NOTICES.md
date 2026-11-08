# Third-Party Notices

This repository contains original configuration files and scripts (MIT), plus
third-party components that remain under their own licenses.

## uosc

- **Project:** uosc — https://github.com/tomasklaen/uosc
- **License:** GNU Lesser General Public License v2.1 (LGPL-2.1)
- **Included files:**
  - `portable_config/scripts/uosc/` (Lua source and the Windows `ziggy` helper)
  - `portable_config/fonts/uosc_icons.otf`
  - `portable_config/fonts/uosc_textures.ttf`
  - `portable_config/script-opts/uosc.conf.example`
- **License text:** `LICENSES/LGPL-2.1.txt`

uosc is used unmodified except for one small change in
`scripts/uosc/lib/ass.lua` to use the Material Icons **Outlined** font for menu
icons. The modified file is distributed as source.

`portable_config/scripts/uosc/bin/ziggy-windows.exe` is the Windows helper
shipped with uosc. Its source is available in the uosc repository:
https://github.com/tomasklaen/uosc/tree/master/src/ziggy

## thumbfast

- **Project:** thumbfast — https://github.com/po5/thumbfast
- **License:** Mozilla Public License 2.0 (MPL-2.0)
- **Included file:** `portable_config/scripts/thumbfast.lua`
- **License text:** `LICENSES/MPL-2.0.txt`

## autoload.lua (mpv)

- **Project:** mpv — https://github.com/mpv-player/mpv
- **File:** `portable_config/scripts/autoload.lua`
- **License:** the file comes from the mpv project. mpv is GPLv2+ by default,
  with many files also available under LGPLv2.1+. See the mpv `Copyright` file
  and the license texts:
  - `LICENSES/GPL-2.0.txt`
  - `LICENSES/LGPL-2.1.txt`

## Material Icons

- **Project:** Google Material Design Icons —
  https://github.com/google/material-design-icons
- **License:** Apache License 2.0
- **Included files:**
  - `portable_config/fonts/MaterialIconsOutlined-Regular.otf`
  - The icon font bundled with uosc (`uosc_icons.otf`)
- **License text:** `LICENSES/Apache-2.0.txt`

## OpenSubtitles API key

`portable_config/scripts/subs_cn.lua` and
`portable_config/script-opts/subs_cn.conf` include the public OpenSubtitles
consumer API key that is bundled with uosc. It is not a personal secret. The
free key is limited to 5 downloads per day; replace it with your own key if you
need more.

## IINA (design inspiration)

The floating on-screen controller is **inspired by** IINA
(https://github.com/iina/iina, GPLv3). No IINA source code is included; the
Lua implementation in `scripts/iina_osc.lua` is original.

## Original files

Unless otherwise noted, the original configuration files and the scripts
`iina_osc.lua`, `subs_cn.lua` and `subs_cn/assrt_extract.ps1` are licensed
under the MIT License. See `LICENSE`.
