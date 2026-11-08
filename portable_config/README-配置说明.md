# mpv 便携配置说明

配置根目录：本仓库的 `portable_config/`
（把它放在 `mpv.exe` 旁边，mpv 会优先使用它，不碰 `%APPDATA%\mpv`）

## 目录结构

```
portable_config/
├─ mpv.conf                 核心配置（画质、音频、字幕、缓存）
├─ input.conf               快捷键
├─ script-opts/
│  ├─ uosc.conf             界面设置（已禁用自带时间轴/控制栏，由 iina_osc 接管）
│  ├─ uosc.conf.example     uosc 全部选项的官方参考（不会被加载）
│  ├─ iina_osc.conf         IINA 浮动控制条尺寸/透明度/隐藏时间
│  ├─ autoload.conf         自动连播设置
│  └─ subs_cn.conf          中文字幕搜索配置（OpenSubtitles key、Assrt 开关）
├─ scripts/
│  ├─ uosc/                 现代悬浮界面（菜单/播放列表/字幕菜单）
│  ├─ iina_osc.lua          IINA 风格浮动控制条（自定义 OSC）
│  ├─ thumbfast.lua         进度条悬停缩略图
│  ├─ autoload.lua          自动加载同目录下一集
│  └─ subs_cn.lua           中文字幕双源搜索（OpenSubtitles + Assrt）
├─ subs_cn/
│  └─ assrt_extract.ps1     Assrt 字幕包解压/选集脚本
├─ fonts/                   uosc 图标 + Material Icons Outlined 字体
├─ screenshots/             截图默认目录
├─ subtitles/               URL / 只读目录时的备用字幕保存位置
├─ watch_later/             播放进度记录
├─ shaders/                 自制/下载的着色器放这里（目前为空）
└─ cache/                   mpv 着色器缓存 + Assrt 字幕缓存（subs_cn/）
```

## IINA 风格界面

当前默认使用自定义的 `iina_osc.lua`，按 IINA 的 Floating OSC 复刻：

- **浮动圆角控制条**：460 × 68 pt，底部居中，半透明深色背景
  - 鼠标静止 2.5 秒后自动隐藏（**播放和暂停时都一样**）
  - 鼠标一动立即重新出现；拖动进度条/音量条、打开菜单或弹窗时保持显示
  - 隐藏时不会挡住画面，也不会拦截鼠标点击
- **上排**：音量图标 + 音量条；倍速后退 / 播放暂停 / 倍速前进；右侧工具栏（全屏、画中画、插件、播放列表、设置）
- **下排**：当前时间 / 进度条 / 总时长；进度条带 IINA 同款细长旋钮
- **悬停进度条**：显示时间提示 + thumbfast 缩略图
- **交互**：拖动进度条 / 音量条；单击视频暂停，双击全屏；右键打开 uosc 菜单
- **倍速**：左右箭头每次 ±0.25x（0.25–4x），非 1x 时播放键两侧显示速度
- **画中画**：Windows 没有系统级 PiP，这里用“置顶 + 缩小窗口”模拟
- **设置齿轮**：打开 4×2 的紧凑图标网格
  （字幕 / 音轨 / 章节 / 选集 / 截图 / 快捷键 / 搜字幕 / 退出），不再是一个大菜单
- **选集按钮**（列表图标）：打开小型剧集列表
  - 只显示 `S02E01 · The Dundies` 这种短标题，不再显示完整文件名
  - 当前集高亮，右侧有滚动条，滚轮可滚动，点击即切换
  - 面板默认 6 行，可用 `playlist_rows` 调整
- **二级菜单**：uosc 的字幕 / 音轨 / 章节 / 快捷键菜单也已缩小
  （26px 行高、190px 最小宽度、6px 圆角、线框图标），和浮动条风格统一

配置在 `script-opts/iina_osc.conf`：

```conf
bar_width=460            # 逻辑宽度（pt）
bar_height=68
bottom_margin=25
autohide_timeout=2.5
background_opacity=0.88  # 0.78 更通透，0.95 更实
playlist_rows=6          # 选集弹窗行数（3-12）
popover_opacity=0.94     # 设置/选集弹窗背景不透明度
```

uosc 菜单的紧凑化在 `script-opts/uosc.conf`：

```conf
menu_item_height=26
menu_min_width=190
menu_padding=3
font_scale=0.92
```

注意：为了让菜单图标和浮动条一致，`scripts/uosc/lib/ass.lua` 里的
`MaterialIconsRound-Regular` 已改成 `MaterialIconsOutlined-Regular`。
更新 uosc 后这一行会被覆盖，需要重新改一次。

限制：

- ASS 无法做真正的背景模糊；IINA 的毛玻璃只能用半透明深色近似
- 保留 Windows 原生标题栏（没有 macOS 红绿灯），否则窗口拖动/缩放会变麻烦
- 没有 IINA 的常驻侧栏；选集用浮动列表弹窗，字幕 / 音轨用紧凑菜单

想恢复 uosc 自带界面：

1. 删除或改名 `scripts/iina_osc.lua`
2. 删除 `uosc.conf` 末尾的 `disable_elements=...` 行
3. 删除 `input.conf` 的 `MBTN_LEFT script-message-to iina_osc click` 行
4. 删除 `input.conf` 的 `WHEEL_UP/WHEEL_DOWN script-message-to iina_osc wheel ...` 两行
5. 如需完全恢复 uosc 图标，把 `scripts/uosc/lib/ass.lua` 里的
   `MaterialIconsOutlined-Regular` 改回 `MaterialIconsRound-Regular`

## 快捷键速查

| 键 | 功能 |
|---|---|
| 空格 / p | 播放 / 暂停 |
| 鼠标左键 | 单击暂停 / 双击全屏；控制条上是按钮、进度条和音量条拖拽 |
| ← / → | 快退 / 快进 5 秒 |
| Shift + ↑ / ↓ | 快退 / 快进 60 秒 |
| ↑ / ↓ | 音量 ±5 |
| m | 静音 |
| f | 全屏 |
| T | 窗口置顶 |
| s / S / Ctrl+s | 截图（带字幕 / 不带字幕 / 窗口含界面） |
| [ / ] | 减速 / 加速 |
| { / } / BS | 半速 / 双速 / 恢复 1 倍 |
| v / j / J | 显示隐藏字幕 / 切换字幕 / 反向切换 |
| **Ctrl+D** | **自动搜索中文字幕（OpenSubtitles + Assrt）** |
| **Ctrl+Shift+D** | **手动搜索字幕（OpenSubtitles 菜单）** |
| z / Z | 字幕延迟 -0.1 / +0.1 秒 |
| **Alt+Z / Alt+X** | **字幕延迟 / 提前 1 秒（自动保存）** |
| a | 切换音轨 |
| l / L | A-B 循环 / 单文件循环 |
| < / > / Enter | 上一集 / 下一集 |
| PGUP / PGDWN | 上一章 / 下一章 |
| o | 打开文件（uosc 菜单） |
| 右键 | uosc 菜单（字幕、音轨、章节、播放列表等） |
| Tab | 显示 / 隐藏控制条 |
| F1 | 当前快捷键帮助 |

## 中文字幕搜索 / 下载（像 IINA，双源）

按 **Ctrl+D** 即可：

1. 从文件名解析片名、年份、季/集
   （例如某部美剧的 `SxxExx` 文件名 → 剧名 / SxxExx）
2. **先搜 OpenSubtitles**（带 `season_number` / `episode_number` / `year` 精准参数）：
   - 有中文结果 → 弹出列表，选 **zh-CN / zh-TW**，点击下载并自动加载
3. **OpenSubtitles 没有中文 → 自动转 Assrt（射手网）**：
   - 搜逐集 zip 或整季/整剧包，自动下载、解压、挑出对应集的中文 ASS/SRT
   - 支持逐集 zip、整季包、整剧包（zip/rar）自动解压和选集
4. 两边都没有 → 右键菜单里可以：
   - 在浏览器打开 Assrt 搜索页
   - 手动搜索（可自己改片名）

手动搜索：**Ctrl+Shift+D**（uosc 内置 OpenSubtitles 菜单）。

字幕会保存为视频同目录的 `<视频名>.chs.ass` / `.chs.srt`，
下次打开由 `sub-auto=fuzzy` 自动挂载。

### 缓存

Assrt 下载的整季/整剧包会缓存在 `portable_config/cache/subs_cn/`。
同一季第二集开始直接命中缓存，不再重复下载。想强制重新下载就删掉该目录。

### 注意

- OpenSubtitles 免费 key 每天 **5 次下载**；Assrt 网页下载没有这个限制。
- Assrt 是通过网页搜索 + 解析下载链接实现的；如果站点改版，可能需要更新脚本。
- 整剧包里的 `.rar` 季包需要系统里有 **7-Zip**（`7z`）；没有的话该季会失败。
- 字幕搜索语言在 `script-opts/subs_cn.conf` 的 `languages=zh-cn,zh-tw`。

### 字幕和音频不同步

- 字幕**快了** → 按 **Alt+Z**（延迟 1 秒，可连按）
- 字幕**慢了** → 按 **Alt+X**（提前 1 秒）
- 微调：`Z` / `z`（±0.1 秒，mpv 默认），或右键菜单 → **字幕同步** → 0.1 秒
- 偏移会自动保存到视频旁边的 `<视频名>.subs_cn.delay`，下次打开自动应用
- 整季统一偏移会读取季文件夹里的 `.subs_cn.delay`；
  可以给整季设置一个统一偏移（右键 → 字幕同步 → 保存为整季偏移）
- 右键菜单 → 字幕同步 → **保存为整季偏移**，可以把当前偏移写进季文件夹

## 常见调整

### 进度条 / 控制栏风格

当前是 B 站式细线：不悬停时只有底部一条极细进度线，悬停时展开显示缩略图和预览时间。
相关选项都在 `script-opts/uosc.conf`：

```conf
timeline_style=line        # 细线
timeline_size=18           # 悬停展开高度，越小越简洁
timeline_line_width=2      # 线宽
timeline_cache=no          # 不显示缓冲纹理
timeline_heatmap=no        # 不显示 YouTube 热力图
progress=windowed          # 窗口模式下保留底部细线
opacity=timeline=0.8,...   # 背景透明度
controls=...               # 控制栏按钮，可自行增删
```

- 想加回缓冲条：`timeline_cache=yes`
- 想显示章节菱形：把 `opacity` 里的 `chapters=0` 删掉
- 想显示 YouTube 热力图：`timeline_heatmap=overlay`

### 4K 屏觉得界面太小

在 `script-opts/uosc.conf` 末尾加：

```conf
scale=1.15
scale_fullscreen=1.1
```

### 想更锐利 / 更省电

`mpv.conf` 中：

```conf
# 更锐（高端显卡可开）
scale=ewa_lanczos4sharpest
# 更省电（放弃高质量预设）
# profile=
# scale=bicubic
```

### 补帧（60 → 160Hz 更顺滑）

`mpv.conf` 取消这三行注释：

```conf
video-sync=display-resample
interpolation=yes
tscale=oversample
```

补帧是“计算中间帧”，可能有肥皂剧效应；不喜欢就注释掉。

### HDR

`gpu-next` + D3D11 下 `target-colorspace-hint=auto` 已能正确输出 HDR 元数据。
如果显示器/HDR 发灰或过曝，把 `auto` 改成 `no` 再试。

### 字幕字体

`mpv.conf` 里 `sub-font='Microsoft YaHei UI'`，可换成任意系统已安装字体。
ASS 字幕默认只缩放、不覆盖原排版（`sub-ass-override=scale`）；想强制统一改成 `force`。

### 加着色器

把 `.glsl` / `.hook` 文件放进 `shaders/`，然后在 `mpv.conf` 里按需加载：

```conf
glsl-shaders=~~/shaders/你的文件.glsl
```

### 更新 uosc

去 https://github.com/tomasklaen/uosc/releases 下载最新 `uosc.zip`，
把 `scripts/uosc/` 和 `fonts/` 覆盖到本目录即可。

## 已知限制（对比 IINA）

- 没有 macOS 的触控板手势、Touch Bar、原生菜单栏。
- 没有常驻播放列表侧栏（uosc 用菜单式播放列表代替）。
- 画中画是“置顶 + 缩小窗口”，不是系统级 PiP。
- 没有内置图形化设置面板，配置靠文本文件。

## 可选下一步

1. **在线视频**：安装 `yt-dlp` 并加入 PATH 后，直接把 B 站/YouTube 链接拖进 mpv 或 `mpv <URL>` 即可。
2. **默认播放器 / 右键菜单**：运行 `installer\mpv-install.bat`（需要管理员权限，会写注册表）。
3. **更多脚本**：sponsorblock（跳过赞助片段）、playlistmanager、mpvacious 等。
