-- ================================================================
--  iina_osc.lua — IINA 风格浮动控制条
--  参考 IINA 1.4/1.5 的 Floating OSC：
--    460 × 68 pt 圆角半透明浮动条，底部居中
--    上排：音量图标 + 音量条 | 倍速后退 / 播放暂停 / 倍速前进 | 工具栏
--    下排：当前时间 | 进度条 | 总时长
--  依赖：uosc（菜单/播放列表/字幕菜单），thumbfast（悬停缩略图）
--  说明：uosc 的 timeline/controls/volume/top_bar 在 uosc.conf 中禁用
-- ================================================================
local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'
local opt = require 'mp.options'

local o = {
    scale = 1,
    bar_width = 460,
    bar_height = 68,
    bottom_margin = 25,
    autohide_timeout = 2.5,
    background_opacity = 0.88,
    icon_font = 'MaterialIconsOutlined-Regular',
    time_font = 'Consolas',
    playlist_rows = 6,
    popover_opacity = 0.94,
}

opt.read_options(o, 'iina_osc')

local ov = mp.create_osd_overlay('ass-events')
ov.z = 0
ov.hidden = true

local state = {
    loaded = false,
    visible = false,
    paused = false,
    time = 0,
    duration = 0,
    volume = 100,
    mute = false,
    fullscreen = false,
    speed = 1,
    chapters = {},
    media_title = '',
    mouse_x = -1,
    mouse_y = -1,
    hover = nil,
    pressed = nil,
    menu_open = false,
    dragging = nil,
    was_paused = false,
    last_drag_end = 0,
    last_seek = 0,
    pending_click = nil,
    last_click_time = 0,
    last_click_x = 0,
    last_click_y = 0,
    outside_press = nil,
    thumb_w = 0,
    thumb_h = 0,
    last_thumb_sec = nil,
    last_thumb_x = nil,
    pip_state = nil,
    popover = nil,
    popover_hover = nil,
    popover_scroll = 0,
    playlist = {},
    playlist_pos = 1,
    playlist_count = 0,
    closed_popover = 0,
}

local last_layout = nil
local last_popover_layout = nil
local popover_at -- forward declaration
local clear_thumb -- forward declaration
local request_render -- forward declaration
local show -- forward declaration
local render_scheduled = false
local last_render = 0

-- ---------------------------------------------------------------- helpers

local function clamp(v, min, max)
    if v < min then return min end
    if v > max then return max end
    return v
end

local function fmt_time(t)
    if not t or t < 0 or t ~= t then t = 0 end
    t = math.floor(t + 0.5)
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    if h > 0 then
        return string.format('%d:%02d:%02d', h, m, s)
    end
    return string.format('%02d:%02d', m, s)
end

local function alpha(opacity)
    opacity = clamp(opacity == nil and 1 or opacity, 0, 1)
    return string.format('%02X', math.floor((1 - opacity) * 255))
end

local function get_scale()
    return (mp.get_property_number('display-hidpi-scale', 1) or 1) * (o.scale or 1)
end

local function txt(ass, x, y, align, value, opts)
    opts = opts or {}
    local tags = string.format(
        '\\pos(%d,%d)\\rDefault\\an%d\\blur%.2f\\fn%s\\fs%.2f\\bord%.2f\\shad0',
        math.floor(x), math.floor(y), align or 5, opts.blur or 0,
        opts.font or 'Microsoft YaHei UI', opts.size or 12, opts.border or 0)
    tags = tags .. '\\1c&H' .. (opts.color or 'FFFFFF')
    if (opts.border or 0) > 0 then
        tags = tags .. '\\3c&H' .. (opts.border_color or '000000')
    end
    if opts.opacity ~= nil then
        tags = tags .. '\\1a&H' .. alpha(opts.opacity) .. '&'
    end
    if opts.bold then tags = tags .. '\\b1' end
    ass:new_event()
    ass:append('{' .. tags .. '}' .. tostring(value))
end

local function shape(ass, x1, y1, x2, y2, opts)
    opts = opts or {}
    local tags = string.format('\\pos(0,0)\\rDefault\\an7\\blur%.2f\\bord%.2f',
        opts.blur or 0, opts.border or 0)
    tags = tags .. '\\1c&H' .. (opts.color or 'FFFFFF')
    if (opts.border or 0) > 0 then
        tags = tags .. '\\3c&H' .. (opts.border_color or '000000')
    end
    if opts.opacity ~= nil then
        tags = tags .. '\\1a&H' .. alpha(opts.opacity) .. '&'
    end
    if opts.border_opacity ~= nil then
        tags = tags .. '\\3a&H' .. alpha(opts.border_opacity) .. '&'
    end
    ass:new_event()
    ass:append('{' .. tags .. '}')
    ass:draw_start()
    if (opts.radius or 0) > 0 then
        ass:round_rect_cw(x1, y1, x2, y2, opts.radius)
    else
        ass:rect_cw(x1, y1, x2, y2)
    end
    ass:draw_stop()
end

local function icon(ass, cx, cy, size, name, opacity, font)
    txt(ass, cx, cy, 5, name, {
        font = font or o.icon_font,
        size = size,
        color = 'FFFFFF',
        opacity = opacity == nil and 0.85 or opacity,
    })
end

-- ---------------------------------------------------------------- layout

local function make_layout(W, H)
    local s = get_scale()
    local bar_w = math.min(o.bar_width * s, W - 20 * s)
    local bar_h = o.bar_height * s
    local x = (W - bar_w) / 2
    local y = H - bar_h - o.bottom_margin * s

    local top_cy = y + 26 * s
    local bottom_cy = y + bar_h - 18 * s
    local pad = 12 * s

    -- 音量
    local vol_icon = { cx = x + 16 * s, cy = top_cy, size = 16 * s }
    local vol = { x1 = x + 32 * s, x2 = x + 102 * s, y = top_cy, h = 4 * s }

    -- 播放控制（IINA: 24px 按钮，间距 24）
    local cx = x + bar_w / 2
    local gap = 48 * s
    local play = { cx = cx, cy = top_cy, size = 24 * s }
    local rewind = { cx = cx - gap, cy = top_cy, size = 18 * s }
    local forward = { cx = cx + gap, cy = top_cy, size = 18 * s }

    -- 工具栏（5 个，右对齐）
    local tw, tg = 24 * s, 4 * s
    local total = 5 * tw + 4 * tg
    local tx = x + bar_w - pad - total
    local toolbar = {}
    for i = 1, 5 do
        toolbar[i] = {
            cx = tx + (i - 1) * (tw + tg) + tw / 2,
            cy = top_cy,
            size = 15 * s,
        }
    end

    -- 下排：时间 / 进度 / 总时长
    local time_w = 46 * s
    local seek = {
        x1 = x + 14 * s + time_w + 6 * s,
        x2 = x + bar_w - 14 * s - time_w - 6 * s,
        y = bottom_cy,
        h = 4 * s,
    }

    local function hit(cx, cy, r)
        return { x1 = cx - r, y1 = cy - r, x2 = cx + r, y2 = cy + r }
    end

    return {
        s = s, x = x, y = y, w = bar_w, h = bar_h,
        top_cy = top_cy, bottom_cy = bottom_cy,
        vol_icon = vol_icon, vol = vol,
        play = play, rewind = rewind, forward = forward,
        toolbar = toolbar,
        seek = seek,
        bar = { x1 = x, y1 = y, x2 = x + bar_w, y2 = y + bar_h },
        hit = {
            play = hit(play.cx, play.cy, 18 * s),
            rewind = hit(rewind.cx, rewind.cy, 16 * s),
            forward = hit(forward.cx, forward.cy, 16 * s),
            vol_icon = hit(vol_icon.cx, vol_icon.cy, 13 * s),
            vol = { x1 = vol.x1 - 4 * s, x2 = vol.x2 + 4 * s, y1 = vol.y - 14 * s, y2 = vol.y + 14 * s },
            seek = { x1 = seek.x1 - 4 * s, x2 = seek.x2 + 4 * s, y1 = seek.y - 14 * s, y2 = seek.y + 14 * s },
            toolbar = {},
        },
    }
end

local function in_rect(r, x, y)
    return r and x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2
end

local function zone_at(x, y)
    local L = last_layout
    if not L or not state.visible then return nil end
    if state.popover then
        local pz = popover_at(x, y)
        if pz then return pz end
    end
    if in_rect(L.hit.play, x, y) then return 'play' end
    if in_rect(L.hit.rewind, x, y) then return 'rewind' end
    if in_rect(L.hit.forward, x, y) then return 'forward' end
    if in_rect(L.hit.vol_icon, x, y) then return 'vol_icon' end
    if in_rect(L.hit.vol, x, y) then return 'vol' end
    if in_rect(L.hit.seek, x, y) then return 'seek' end
    for i = 1, 5 do
        local r = L.toolbar[i]
        if r and in_rect(L.hit.toolbar[i], x, y) then return 'tool_' .. i end
    end
    if in_rect(L.bar, x, y) then return 'bar' end
    return nil
end

-- tool hitboxes need to be built after toolbar is known
local function update_tool_hits(L)
    for i = 1, 5 do
        local b = L.toolbar[i]
        L.hit.toolbar[i] = {
            x1 = b.cx - 15 * L.s, y1 = b.cy - 15 * L.s,
            x2 = b.cx + 15 * L.s, y2 = b.cy + 15 * L.s,
        }
    end
end

-- ---------------------------------------------------------------- popovers

local SETTINGS_ITEMS = {
    { icon = 'subtitles', label = '字幕', action = 'subtitles' },
    { icon = 'audiotrack', label = '音轨', action = 'audio' },
    { icon = 'bookmark', label = '章节', action = 'chapters' },
    { icon = 'list_alt', label = '选集', action = 'playlist' },
    { icon = 'photo_camera', label = '截图', action = 'screenshot' },
    { icon = 'keyboard', label = '快捷键', action = 'keybinds' },
    { icon = 'search', label = '搜字幕', action = 'subs' },
    { icon = 'power_settings_new', label = '退出', action = 'quit' },
}

local function short_episode_title(item)
    local filename = item and item.filename or ''
    local base = filename:match('([^/\\]+)$') or filename
    base = base:gsub('%.[^.]+$', '')
    local ss, ee = base:match('[Ss](%d+)[Ee](%d+)')
    if ss then
        local tag = string.format('S%02dE%02d', tonumber(ss), tonumber(ee))
        local rest = base:match('[Ss]%d+[Ee]%d+%s*[-–—]?%s*(.*)') or ''
        rest = rest:gsub('^[%._%s%-]+', '')
        rest = rest:gsub('%s*%b()%s*$', '')
        rest = rest:gsub('%s*%b[]%s*$', '')
        rest = rest:match('^%s*(.-)%s*$')
        if rest ~= '' and not rest:match('^%d+p') and not rest:match('^%d+%.?%d*$') then
            if #rest > 34 then rest = rest:sub(1, 34) .. '…' end
            return tag .. ' · ' .. rest
        end
        return tag
    end
    if #base > 42 then base = base:sub(1, 42) .. '…' end
    return base
end

local function make_settings_popover(L, W, H)
    local s = L.s
    local cols, rows = 4, 2
    local cw, ch = 66 * s, 64 * s
    local pad = 10 * s
    local title_h = 30 * s
    local w = cols * cw + pad * 2
    local h = title_h + rows * ch + pad
    local x = clamp(L.toolbar[5].cx - w / 2, 8 * s, W - w - 8 * s)
    local y = L.y - h - 8 * s
    if y < 8 * s then y = 8 * s end

    local cells = {}
    for i, item in ipairs(SETTINGS_ITEMS) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = x + pad + col * cw + cw / 2
        local cy = y + title_h + row * ch + ch / 2
        cells[i] = {
            x1 = cx - cw / 2 + 3 * s, y1 = cy - ch / 2 + 3 * s,
            x2 = cx + cw / 2 - 3 * s, y2 = cy + ch / 2 - 3 * s,
            cx = cx, cy = cy, item = item,
        }
    end

    return {
        kind = 'settings', x = x, y = y, w = w, h = h, title_h = title_h,
        cells = cells,
        close = { x1 = x + w - 28 * s, y1 = y + 3 * s, x2 = x + w - 6 * s, y2 = y + 27 * s },
        panel = { x1 = x, y1 = y, x2 = x + w, y2 = y + h },
    }
end

local function playlist_rows()
    return math.floor(clamp(tonumber(o.playlist_rows) or 6, 3, 12))
end

local function make_playlist_popover(L, W, H)
    local s = L.s
    local w = 330 * s
    local row_h = 30 * s
    local visible = playlist_rows()
    local title_h = 32 * s
    local pad = 8 * s
    local h = title_h + visible * row_h + pad
    local x = clamp(L.toolbar[4].cx - w / 2, 8 * s, W - w - 8 * s)
    local y = L.y - h - 8 * s
    if y < 8 * s then y = 8 * s end

    local total = #state.playlist
    local max_scroll = math.max(0, total - visible)
    local scroll = clamp(state.popover_scroll, 0, max_scroll)
    state.popover_scroll = scroll

    local rows = {}
    for i = 1, visible do
        local idx = scroll + i
        local item = state.playlist[idx]
        if not item then break end
        rows[i] = {
            x1 = x + pad, y1 = y + title_h + (i - 1) * row_h,
            x2 = x + w - pad - 10 * s, y2 = y + title_h + i * row_h,
            idx = idx, item = item,
        }
    end

    local scrollbar = nil
    if max_scroll > 0 then
        local ty1 = y + title_h + 4 * s
        local ty2 = y + h - pad
        local thumb_h = math.max(12 * s, (ty2 - ty1) * visible / math.max(total, 1))
        local thumb_y = ty1 + (ty2 - ty1) * scroll / max_scroll
        scrollbar = {
            x1 = x + w - 7 * s, y1 = ty1, x2 = x + w - 4 * s, y2 = ty2,
            thumb_y1 = thumb_y, thumb_y2 = thumb_y + thumb_h,
        }
    end

    return {
        kind = 'playlist', x = x, y = y, w = w, h = h, title_h = title_h,
        rows = rows, visible = visible, scroll = scroll, max_scroll = max_scroll,
        row_h = row_h, scrollbar = scrollbar,
        close = { x1 = x + w - 28 * s, y1 = y + 4 * s, x2 = x + w - 6 * s, y2 = y + 28 * s },
        panel = { x1 = x, y1 = y, x2 = x + w, y2 = y + h },
    }
end

function popover_at(x, y)
    local P = last_popover_layout
    if not P then return nil end
    if in_rect(P.close, x, y) then return 'pop_close' end
    if P.kind == 'settings' then
        for i, cell in ipairs(P.cells) do
            if in_rect(cell, x, y) then return 'pop_cell_' .. i end
        end
        if in_rect(P.panel, x, y) then return 'popover' end
    elseif P.kind == 'playlist' then
        for i, row in ipairs(P.rows) do
            if in_rect(row, x, y) then return 'pop_row_' .. i end
        end
        if in_rect(P.panel, x, y) then return 'popover' end
    end
    return nil
end

local function close_popover()
    if not state.popover then return end
    state.popover = nil
    state.popover_hover = nil
    last_popover_layout = nil
    request_render()
end

local function toggle_popover(kind)
    if state.popover == kind then
        close_popover()
        return
    end
    state.popover = kind
    state.popover_hover = nil
    state.hover = nil
    clear_thumb()
    if kind == 'playlist' then
        local pos = state.playlist_pos or 1
        state.popover_scroll = clamp(pos - 4, 0, math.max(0, #state.playlist - playlist_rows()))
    end
    show()
    request_render()
end

local function popover_action(action)
    if action == 'subtitles' then
        close_popover()
        mp.commandv('script-binding', 'uosc/subtitles')
    elseif action == 'audio' then
        close_popover()
        mp.commandv('script-binding', 'uosc/audio')
    elseif action == 'chapters' then
        close_popover()
        mp.commandv('script-binding', 'uosc/chapters')
    elseif action == 'playlist' then
        toggle_popover('playlist')
    elseif action == 'screenshot' then
        close_popover()
        mp.commandv('screenshot')
    elseif action == 'keybinds' then
        close_popover()
        mp.commandv('script-binding', 'uosc/keybinds')
    elseif action == 'subs' then
        close_popover()
        mp.commandv('script-binding', 'subs_cn/find')
    elseif action == 'quit' then
        mp.commandv('quit')
    end
end

-- ---------------------------------------------------------------- drawing

local function draw_slider(ass, L, x1, x2, cy, h, value, knob)
    local radius = h / 2
    shape(ass, x1, cy - h / 2, x2, cy + h / 2, {
        color = 'FFFFFF', opacity = 0.16, radius = radius,
    })
    local kx = x1 + (x2 - x1) * clamp(value, 0, 1)
    if kx > x1 then
        shape(ass, x1, cy - h / 2, kx, cy + h / 2, {
            color = 'FFFFFF', opacity = 0.38, radius = radius,
        })
    end
    if knob == 'circle' then
        shape(ass, kx - 6 * L.s, cy - 6 * L.s, kx + 6 * L.s, cy + 6 * L.s, {
            color = 'FFFFFF', opacity = 0.88, radius = 6 * L.s,
        })
    else
        local kw, kh = 3 * L.s, 15 * L.s
        shape(ass, kx - kw / 2, cy - kh / 2, kx + kw / 2, cy + kh / 2, {
            color = 'FFFFFF', opacity = 0.82, radius = 1 * L.s,
        })
    end
end

local function render_popover(ass, W, H, L)
    local P
    if state.popover == 'settings' then
        P = make_settings_popover(L, W, H)
    elseif state.popover == 'playlist' then
        P = make_playlist_popover(L, W, H)
    end
    if not P then return end
    last_popover_layout = P
    local s = L.s

    shape(ass, P.x - 3 * s, P.y - 3 * s, P.x + P.w + 3 * s, P.y + P.h + 3 * s, {
        color = '000000', opacity = 0.35, radius = 10 * s, blur = 10 * s,
    })
    shape(ass, P.x, P.y, P.x + P.w, P.y + P.h, {
        color = '0A0A0A', opacity = o.popover_opacity, radius = 8 * s,
        border = 1 * s, border_color = 'FFFFFF', border_opacity = 0.08,
    })

    local title = P.kind == 'settings' and '设置' or '选集'
    txt(ass, P.x + 14 * s, P.y + P.title_h / 2, 4, title, {
        size = 11 * s, color = 'FFFFFF', opacity = 0.9, bold = true,
    })

    local close_op = state.popover_hover == 'pop_close' and 1.0 or 0.68
    icon(ass, P.close.x1 + (P.close.x2 - P.close.x1) / 2,
        P.close.y1 + (P.close.y2 - P.close.y1) / 2, 12 * s, 'close', close_op)

    if P.kind == 'settings' then
        for i, cell in ipairs(P.cells) do
            local zone = 'pop_cell_' .. i
            local hov = state.popover_hover == zone
            local pressed = state.pressed == zone
            if hov or pressed then
                shape(ass, cell.x1, cell.y1, cell.x2, cell.y2, {
                    color = 'FFFFFF', opacity = pressed and 0.12 or 0.08, radius = 6 * s,
                })
            end
            icon(ass, cell.cx, cell.cy - 7 * s, 20 * s, cell.item.icon, hov and 1.0 or 0.85)
            txt(ass, cell.cx, cell.cy + 16 * s, 5, cell.item.label, {
                size = 9 * s, color = 'FFFFFF', opacity = hov and 0.95 or 0.7,
            })
        end
    elseif P.kind == 'playlist' then
        txt(ass, P.x + P.w - 38 * s, P.y + P.title_h / 2, 6,
            string.format('%d/%d', state.playlist_pos or 1, #state.playlist), {
                font = o.time_font, size = 9 * s, color = 'FFFFFF', opacity = 0.45,
            })
        for i, row in ipairs(P.rows) do
            local zone = 'pop_row_' .. i
            local hov = state.popover_hover == zone
            local current = row.item.current or row.idx == (state.playlist_pos or 0)
            if current or hov then
                shape(ass, row.x1, row.y1 + 1 * s, row.x2, row.y2 - 1 * s, {
                    color = 'FFFFFF', opacity = current and 0.10 or 0.06, radius = 4 * s,
                })
            end
            if current then
                icon(ass, row.x1 + 12 * s, (row.y1 + row.y2) / 2, 11 * s,
                    'play_arrow', 1.0, 'MaterialIconsRound-Regular')
            else
                txt(ass, row.x1 + 12 * s, (row.y1 + row.y2) / 2, 5,
                    string.format('%02d', row.idx), {
                        font = o.time_font, size = 9 * s, color = 'FFFFFF', opacity = 0.35,
                    })
            end
            txt(ass, row.x1 + 26 * s, (row.y1 + row.y2) / 2, 4,
                short_episode_title(row.item), {
                    size = 10 * s, color = 'FFFFFF', opacity = current and 0.95 or 0.78,
                })
        end
        if P.scrollbar then
            shape(ass, P.scrollbar.x1, P.scrollbar.y1, P.scrollbar.x2, P.scrollbar.y2, {
                color = 'FFFFFF', opacity = 0.08, radius = 1.5 * s,
            })
            shape(ass, P.scrollbar.x1, P.scrollbar.thumb_y1, P.scrollbar.x2, P.scrollbar.thumb_y2, {
                color = 'FFFFFF', opacity = 0.35, radius = 1.5 * s,
            })
        end
    end
end

function request_render()
    if render_scheduled then return end
    render_scheduled = true
    mp.add_timeout(0.016, function()
        render_scheduled = false
        render()
    end)
end

function render()
    if not state.loaded then
        if not ov.hidden then
            ov.data = ''
            ov.hidden = true
            ov:update()
        end
        return
    end

    local W, H = mp.get_osd_size()
    if W <= 0 or H <= 0 then return end
    if not state.visible then
        if not ov.hidden then
            ov.data = ''
            ov.hidden = true
            ov:update()
        end
        return
    end

    local L = make_layout(W, H)
    update_tool_hits(L)
    last_layout = L
    local s = L.s
    local ass = assdraw.ass_new()

    -- 阴影 + 背景
    shape(ass, L.x - 3 * s, L.y - 3 * s, L.x + L.w + 3 * s, L.y + L.h + 3 * s, {
        color = '000000', opacity = 0.30, radius = 12 * s, blur = 10 * s,
    })
    shape(ass, L.x, L.y, L.x + L.w, L.y + L.h, {
        color = '0A0A0A', opacity = o.background_opacity, radius = 8 * s,
        border = 1 * s, border_color = 'FFFFFF', border_opacity = 0.07,
    })
    -- 顶部细微高光，模拟玻璃边缘
    shape(ass, L.x + 10 * s, L.y + 0.8 * s, L.x + L.w - 10 * s, L.y + 1.6 * s, {
        color = 'FFFFFF', opacity = 0.05, radius = 0.8 * s,
    })

    -- 进度条
    if state.duration > 0 then
        local p = clamp(state.time / state.duration, 0, 1)
        local radius = L.seek.h / 2
        shape(ass, L.seek.x1, L.seek.y - radius, L.seek.x2, L.seek.y + radius, {
            color = 'FFFFFF', opacity = 0.16, radius = radius,
        })
        local kx = L.seek.x1 + (L.seek.x2 - L.seek.x1) * p
        if kx > L.seek.x1 then
            shape(ass, L.seek.x1, L.seek.y - radius, kx, L.seek.y + radius, {
                color = 'FFFFFF', opacity = 0.38, radius = radius,
            })
        end

        -- 章节线
        for _, ch in ipairs(state.chapters) do
            if ch.time and ch.time > 0 and ch.time < state.duration then
                local cxp = L.seek.x1 + (L.seek.x2 - L.seek.x1) * (ch.time / state.duration)
                shape(ass, cxp - 0.5 * s, L.seek.y - radius, cxp + 0.5 * s, L.seek.y + radius, {
                    color = 'FFFFFF', opacity = 0.22,
                })
            end
        end

        -- 旋钮
        local kw, kh = 3 * s, 15 * s
        shape(ass, kx - kw / 2, L.seek.y - kh / 2, kx + kw / 2, L.seek.y + kh / 2, {
            color = 'FFFFFF', opacity = 0.82, radius = 1 * s,
        })
    end

    -- 时间
    txt(ass, L.x + 14 * s, L.bottom_cy, 4, fmt_time(state.time), {
        font = o.time_font, size = 11 * s, color = 'FFFFFF', opacity = 0.62,
    })
    txt(ass, L.x + L.w - 14 * s, L.bottom_cy, 6, fmt_time(state.duration), {
        font = o.time_font, size = 11 * s, color = 'FFFFFF', opacity = 0.62,
    })

    -- 音量条
    local vol_value = state.mute and 0 or clamp((state.volume or 0) / 100, 0, 1)
    draw_slider(ass, L, L.vol.x1, L.vol.x2, L.vol.y, L.vol.h, vol_value, 'circle')

    -- 图标
    local function icon_opacity(zone)
        if state.pressed == zone then return 0.55 end
        if state.hover == zone then return 1.0 end
        return 0.85
    end

    local vol_icon = 'volume_up'
    if state.mute or (state.volume or 0) <= 0 then
        vol_icon = 'volume_off'
    elseif (state.volume or 0) < 50 then
        vol_icon = 'volume_down'
    end
    local filled = 'MaterialIconsRound-Regular'
    icon(ass, L.vol_icon.cx, L.vol_icon.cy, L.vol_icon.size, vol_icon, icon_opacity('vol_icon'), filled)

    icon(ass, L.rewind.cx, L.rewind.cy, L.rewind.size, 'fast_rewind', icon_opacity('rewind'), filled)
    icon(ass, L.play.cx, L.play.cy, L.play.size, state.paused and 'play_arrow' or 'pause', icon_opacity('play'), filled)
    icon(ass, L.forward.cx, L.forward.cy, L.forward.size, 'fast_forward', icon_opacity('forward'), filled)

    local tool_icons = {
        state.fullscreen and 'fullscreen_exit' or 'fullscreen',
        'picture_in_picture_alt',
        'extension',
        'list_alt',
        'settings',
    }
    for i = 1, 5 do
        local b = L.toolbar[i]
        icon(ass, b.cx, b.cy, b.size, tool_icons[i], icon_opacity('tool_' .. i))
    end

    -- 倍速标签
    if state.speed and math.abs(state.speed - 1) > 0.001 then
        local label = string.format('%.2gx', state.speed)
        txt(ass, L.play.cx - 62 * s, L.top_cy, 5, label, {
            size = 10 * s, color = 'FFFFFF', opacity = 0.45,
        })
        txt(ass, L.play.cx + 62 * s, L.top_cy, 5, label, {
            size = 10 * s, color = 'FFFFFF', opacity = 0.45,
        })
    end

    -- 悬停进度提示 + 缩略图
    if state.hover == 'seek' and state.duration > 0 and not state.popover then
        local mx = state.mouse_x
        local frac = clamp((mx - L.seek.x1) / (L.seek.x2 - L.seek.x1), 0, 1)
        local sec = frac * state.duration
        local tw = 48 * s
        local th = 22 * s
        local tx = clamp(mx, L.x + tw / 2 + 8 * s, L.x + L.w - tw / 2 - 8 * s)
        local ty = L.seek.y - L.seek.h / 2 - 10 * s
        shape(ass, tx - tw / 2, ty - th, tx + tw / 2, ty, {
            color = '000000', opacity = 0.78, radius = 4 * s,
        })
        txt(ass, tx, ty - th / 2, 5, fmt_time(sec), {
            font = o.time_font, size = 11 * s, color = 'FFFFFF', opacity = 0.95,
        })

        if state.thumb_w > 0 and state.thumb_h > 0 then
            local thumb_x = clamp(mx - state.thumb_w / 2, 0, W - state.thumb_w)
            local thumb_y = ty - th - state.thumb_h - 8 * s
            if state.last_thumb_sec ~= math.floor(sec) or state.last_thumb_x ~= math.floor(thumb_x / 4) then
                mp.commandv('script-message-to', 'thumbfast', 'thumb', tostring(sec), tostring(thumb_x), tostring(thumb_y))
                state.last_thumb_sec = math.floor(sec)
                state.last_thumb_x = math.floor(thumb_x / 4)
            end
        end
    end

    if state.popover then
        render_popover(ass, W, H, L)
    else
        last_popover_layout = nil
    end

    ov.res_x, ov.res_y = W, H
    ov.data = ass.text
    ov.hidden = false
    ov:update()
end

-- ---------------------------------------------------------------- mouse / input

local ok_ffi, ffi = pcall(require, 'ffi')
local ok_bit, bit = pcall(require, 'bit')
local user32 = nil
if ok_ffi and ok_bit then
    pcall(function()
        ffi.cdef[[short GetAsyncKeyState(int vKey);]]
        user32 = ffi.load('user32')
    end)
end

local function left_button_down()
    if not user32 then return false end
    return bit.band(user32.GetAsyncKeyState(0x01), 0x8000) ~= 0
end

function clear_thumb()
    if state.last_thumb_sec ~= nil then
        mp.commandv('script-message-to', 'thumbfast', 'clear')
        state.last_thumb_sec = nil
        state.last_thumb_x = nil
    end
end

local hide_timer = mp.add_timeout(o.autohide_timeout, function() end)
hide_timer:kill()

function show()
    if not state.loaded then return end
    if not state.visible then
        state.visible = true
        request_render()
    end
    hide_timer:kill()
    hide_timer:resume()
end

local function hide()
    if not state.visible then return end
    state.visible = false
    state.hover = nil
    state.pressed = nil
    state.popover = nil
    state.popover_hover = nil
    last_popover_layout = nil
    clear_thumb()
    request_render()
end

hide_timer:kill()
-- replace the callback
hide_timer = mp.add_timeout(o.autohide_timeout, function()
    -- 播放/暂停都一样：鼠标静止几秒就隐藏；菜单/拖动/弹窗打开时例外
    if not state.visible or state.menu_open or state.dragging or state.popover then
        hide_timer:kill()
        hide_timer:resume()
        return
    end
    hide()
end)
hide_timer:kill()

local function reset_hide_timer()
    hide_timer:kill()
    if state.visible then hide_timer:resume() end
end

local function seek_from_x(x, exact)
    local L = last_layout
    if not L or not state.duration or state.duration <= 0 then return end
    local frac = clamp((x - L.seek.x1) / (L.seek.x2 - L.seek.x1), 0, 1)
    local target = frac * state.duration
    local now = mp.get_time()
    if not exact then
        if now - state.last_seek < 0.04 then return end
        state.last_seek = now
        mp.commandv('seek', tostring(target), 'absolute+keyframes')
    else
        mp.commandv('seek', tostring(target), 'absolute+exact')
    end
end

local function set_volume_from_x(x)
    local L = last_layout
    if not L then return end
    local frac = clamp((x - L.vol.x1) / (L.vol.x2 - L.vol.x1), 0, 1)
    mp.set_property_number('volume', frac * 100)
    if state.mute then mp.set_property_bool('mute', false) end
end

local function speed_delta(delta)
    local speed = mp.get_property_number('speed', 1) or 1
    speed = clamp(speed + delta, 0.25, 4)
    mp.set_property_number('speed', speed)
    mp.osd_message(string.format('播放速度 %.2gx', speed), 1)
end

local function toggle_pip()
    if state.pip_state then
        mp.set_property_number('window-scale', state.pip_state.scale)
        mp.set_property_bool('ontop', state.pip_state.ontop)
        state.pip_state = nil
    else
        state.pip_state = {
            scale = mp.get_property_number('window-scale', 1) or 1,
            ontop = mp.get_property_bool('ontop', false),
        }
        mp.set_property_bool('ontop', true)
        mp.set_property_number('window-scale', 0.35)
    end
end

local function outside_click(x, y)
    local now = mp.get_time()
    if state.pending_click then
        state.pending_click:kill()
        state.pending_click = nil
        mp.commandv('cycle', 'fullscreen')
        return
    end
    state.last_click_time = now
    state.last_click_x = x
    state.last_click_y = y
    state.pending_click = mp.add_timeout(0.28, function()
        state.pending_click = nil
        mp.commandv('cycle', 'pause')
    end)
end

local function on_click()
    if not state.loaded then return end
    local pos = mp.get_property_native('mouse-pos')
    local x = pos and pos.x or state.mouse_x
    local y = pos and pos.y or state.mouse_y
    if not x or not y then return end

    local zone = zone_at(x, y)
    local now = mp.get_time()

    if state.popover then
        local pz = popover_at(x, y)
        if pz == 'pop_close' then
            close_popover()
            return
        elseif pz and pz:match('^pop_cell_') then
            local i = tonumber(pz:match('%d+'))
            if i and SETTINGS_ITEMS[i] then popover_action(SETTINGS_ITEMS[i].action) end
            return
        elseif pz and pz:match('^pop_row_') then
            local i = tonumber(pz:match('%d+'))
            local P = last_popover_layout
            local row = P and P.rows[i]
            if row then
                mp.commandv('set', 'playlist-pos-1', tostring(row.idx))
                close_popover()
            end
            return
        elseif pz == 'popover' then
            return
        end
        -- 再点一次同一个按钮：关闭弹窗
        local anchor = state.popover == 'playlist' and 'tool_4' or 'tool_5'
        if zone == anchor then
            close_popover()
            return
        end
        -- 点在弹窗外面：先关闭弹窗；如果点在控制条上，继续处理控制条
        close_popover()
        state.closed_popover = now
        if not zone then return end
    end

    if state.closed_popover and state.closed_popover > 0
        and now - state.closed_popover < 0.3 and (not zone or zone == 'bar') then
        state.closed_popover = 0
        return
    end

    if zone and zone ~= 'bar' then
        if state.pending_click then
            state.pending_click:kill()
            state.pending_click = nil
        end
        if zone == 'play' then
            mp.commandv('cycle', 'pause')
        elseif zone == 'rewind' then
            speed_delta(-0.25)
        elseif zone == 'forward' then
            speed_delta(0.25)
        elseif zone == 'vol_icon' then
            mp.commandv('cycle', 'mute')
        elseif zone == 'vol' then
            set_volume_from_x(x)
        elseif zone == 'seek' then
            seek_from_x(x, true)
        elseif zone == 'tool_1' then
            mp.commandv('cycle', 'fullscreen')
        elseif zone == 'tool_2' then
            toggle_pip()
        elseif zone == 'tool_3' then
            mp.commandv('script-binding', 'uosc/keybinds')
        elseif zone == 'tool_4' then
            toggle_popover('playlist')
        elseif zone == 'tool_5' then
            toggle_popover('settings')
        end
        request_render()
        return
    end

    if zone == 'bar' then return end

    -- 视频区域：单击暂停，双击全屏
    if state.outside_press then
        local moved = math.abs(x - state.outside_press.x) + math.abs(y - state.outside_press.y)
        state.outside_press = nil
        if moved > 8 * get_scale() then return end
    end
    if now - state.last_click_time < 0.35
        and math.abs(x - state.last_click_x) < 10 * get_scale()
        and math.abs(y - state.last_click_y) < 10 * get_scale() then
        if state.pending_click then
            state.pending_click:kill()
            state.pending_click = nil
        end
        mp.commandv('cycle', 'fullscreen')
        state.last_click_time = 0
        return
    end
    outside_click(x, y)
end

local function on_press(x, y)
    local zone = zone_at(x, y)
    if state.popover then
        local pz = popover_at(x, y)
        if pz then
            state.pressed = pz
            request_render()
            return
        end
        close_popover()
        state.closed_popover = mp.get_time()
        if not zone then
            state.outside_press = { x = x, y = y }
            return
        end
    end
    if zone == 'seek' then
        state.dragging = 'seek'
        state.was_paused = state.paused
        mp.set_property_bool('pause', true)
        seek_from_x(x, false)
    elseif zone == 'vol' then
        state.dragging = 'vol'
        set_volume_from_x(x)
    elseif zone and zone ~= 'bar' then
        state.pressed = zone
        request_render()
    end
end

local function on_drag(x, y)
    if state.dragging == 'seek' then
        seek_from_x(x, false)
    elseif state.dragging == 'vol' then
        set_volume_from_x(x)
    end
end

local function on_release(x, y)
    if state.dragging == 'seek' then
        seek_from_x(x, true)
        if not state.was_paused then
            mp.set_property_bool('pause', false)
        end
        state.last_drag_end = mp.get_time()
    elseif state.dragging == 'vol' then
        set_volume_from_x(x)
        state.last_drag_end = mp.get_time()
    end
    state.dragging = nil
    state.pressed = nil
    request_render()
end

-- 轮询鼠标左键（Windows）；避免和 uosc 的鼠标处理抢事件
local mouse_down = false
if user32 then
    mp.add_periodic_timer(0.016, function()
        if not state.loaded then return end
        local down = left_button_down()
        local pos = mp.get_property_native('mouse-pos')
        if pos then state.mouse_x, state.mouse_y = pos.x, pos.y end
        if down and not mouse_down then
            state.outside_press = { x = state.mouse_x, y = state.mouse_y }
            on_press(state.mouse_x, state.mouse_y)
        elseif not down and mouse_down then
            on_release(state.mouse_x, state.mouse_y)
        elseif down and state.dragging then
            on_drag(state.mouse_x, state.mouse_y)
        end
        mouse_down = down
    end)
end

-- ---------------------------------------------------------------- feedback

mp.observe_property('mouse-pos', 'native', function(_, pos)
    if not pos then return end
    local moved = math.abs(pos.x - state.mouse_x) + math.abs(pos.y - state.mouse_y) > 1
    state.mouse_x, state.mouse_y = pos.x, pos.y
    if moved then
        if not state.visible then
            show()
        else
            reset_hide_timer()
        end
        local hover = state.visible and zone_at(pos.x, pos.y) or nil
        if hover ~= state.hover then
            state.hover = hover
            state.popover_hover = (hover and hover:match('^pop')) and hover or nil
            if hover ~= 'seek' then clear_thumb() end
            request_render()
        end
    end
end)

mp.observe_property('pause', 'bool', function(_, v)
    state.paused = v == true
    request_render()
end)
mp.observe_property('time-pos', 'number', function(_, v)
    state.time = v or 0
    if state.visible and not state.paused then
        local now = mp.get_time()
        if now - last_render > 0.08 then
            last_render = now
            request_render()
        end
    end
end)
mp.observe_property('duration', 'number', function(_, v)
    state.duration = v or 0
    request_render()
end)
mp.observe_property('volume', 'number', function(_, v)
    state.volume = v or 0
    request_render()
end)
mp.observe_property('mute', 'bool', function(_, v)
    state.mute = v == true
    request_render()
end)
mp.observe_property('fullscreen', 'bool', function(_, v)
    state.fullscreen = v == true
    request_render()
end)
mp.observe_property('speed', 'number', function(_, v)
    state.speed = v or 1
    request_render()
end)
mp.observe_property('chapter-list', 'native', function(_, v)
    state.chapters = v or {}
    request_render()
end)
mp.observe_property('media-title', 'string', function(_, v)
    state.media_title = v or ''
end)
mp.observe_property('playlist', 'native', function(_, v)
    state.playlist = v or {}
    state.playlist_count = #state.playlist
    request_render()
end)
mp.observe_property('playlist-pos-1', 'number', function(_, v)
    state.playlist_pos = v or 1
    request_render()
end)
mp.observe_property('osd-dimensions', 'native', function() request_render() end)

-- uosc 菜单打开时隐藏控制条，避免遮挡
mp.observe_property('user-data/uosc/menu/type', 'string', function(_, v)
    state.menu_open = v ~= nil and v ~= ''
    if state.menu_open then
        hide()
    elseif state.hover then
        show()
    end
end)

mp.register_script_message('thumbfast-info', function(json)
    local data = utils.parse_json(json)
    if data and data.width and data.height then
        state.thumb_w, state.thumb_h = data.width, data.height
    end
end)

mp.register_script_message('click', on_click)
mp.register_script_message('show', function()
    show()
    request_render()
end)
mp.register_script_message('hide', hide)
mp.register_script_message('toggle', function()
    if state.visible then hide() else show() end
end)
mp.register_script_message('wheel', function(dir)
    dir = tonumber(dir) or 0
    if state.popover == 'playlist' then
        local P = last_popover_layout
        if P and in_rect(P.panel, state.mouse_x, state.mouse_y) then
            state.popover_scroll = clamp(state.popover_scroll + (dir > 0 and 1 or -1), 0, P.max_scroll)
            request_render()
            return
        end
    end
    if state.hover == 'seek' and (state.duration or 0) > 0 then
        mp.commandv('seek', tostring(dir * 5))
    else
        mp.commandv('add', 'volume', tostring(dir > 0 and -2 or 2))
    end
end)
mp.register_script_message('debug-popover', function()
    msg.info(('popover state=%s count=%d pos=%d'):format(
        tostring(state.popover), #state.playlist, state.playlist_pos or 0))
end)
mp.register_script_message('debug-mouse', function()
    msg.info('mouse-pos = ' .. utils.format_json(mp.get_property_native('mouse-pos')))
end)

mp.register_event('file-loaded', function()
    state.loaded = true
    state.pip_state = nil
    state.time = mp.get_property_number('time-pos', 0) or 0
    state.duration = mp.get_property_number('duration', 0) or 0
    state.volume = mp.get_property_number('volume', 100) or 100
    state.mute = mp.get_property_bool('mute', false)
    state.paused = mp.get_property_bool('pause', false)
    state.fullscreen = mp.get_property_bool('fullscreen', false)
    state.speed = mp.get_property_number('speed', 1) or 1
    state.chapters = mp.get_property_native('chapter-list') or {}
    state.playlist = mp.get_property_native('playlist') or {}
    state.playlist_pos = mp.get_property_number('playlist-pos-1', 1) or 1
    state.playlist_count = #state.playlist
    show()
    request_render()
end)

mp.register_event('end-file', function()
    state.loaded = false
    state.visible = false
    clear_thumb()
    request_render()
end)

mp.register_event('shutdown', function()
    ov:remove()
end)

-- 初始隐藏
ov.data = ''
ov.hidden = true
ov:update()
