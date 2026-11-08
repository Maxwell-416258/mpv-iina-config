-- ================================================================
--  subs_cn.lua — 中文字幕一键搜索/下载
--    Ctrl+D       自动搜索：OpenSubtitles 优先，没有中文就转 Assrt
--    Ctrl+Shift+D 手动搜索菜单（uosc 内置 OpenSubtitles）
--  依赖: uosc 自带的 ziggy-windows.exe、Windows 的 curl/powershell
-- ================================================================
local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local opts = require 'mp.options'

local o = {
    api_key = 'b0rd16N0bp7DETMpO4pYZwIqmQkZbYQr',
    agent = 'mpv-subs-cn v1.0',
    languages = 'zh-cn,zh-tw',
    max_items = 20,
    use_assrt = true,
}

opts.read_options(o, 'subs_cn')

local UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
local busy = false
local active_dest = nil
local active_episode = nil
local active_video_base = nil
local active_assrt_url = nil
local active_info = nil

-- ---------------------------------------------------------------- basic

local function is_url(path)
    return path and path:match('^%a[%w+.-]*://') ~= nil
end

local function basename(path)
    return path:match('([^/\\]+)$') or path
end

local function dirname(path)
    return path:match('^(.*)[/\\][^/\\]*$') or '.'
end

local function strip_ext(name)
    return name:gsub('%.[^.]+$', '')
end

local function expand(p)
    return mp.command_native({ 'expand-path', p })
end

local function url_encode(s)
    return (tostring(s):gsub('([^%w%-_%.~])', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

local function url_decode(s)
    return (s:gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function read_file(path)
    local f, err = io.open(path, 'rb')
    if not f then return nil, err end
    local data = f:read('*a')
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, 'wb')
    if not f then return nil, err end
    local ok, werr = f:write(data)
    f:close()
    if not ok then return nil, werr end
    return true
end

-- ---------------------------------------------------------------- subtitle delay

local function delay_paths(path)
    if not path or path == '' then return nil, nil end
    return path .. '.subs_cn.delay',
        utils.join_path(dirname(path), '.subs_cn.delay')
end

local function read_delay(p)
    local f = io.open(p, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return tonumber((s or ''):match('%-?%d+%.?%d*'))
end

local function write_delay(p, value)
    local f, err = io.open(p, 'w')
    if not f then return nil, err end
    f:write(string.format('%.3f\n', value))
    f:close()
    return true
end

local function current_delay()
    return mp.get_property_number('sub-delay', 0) or 0
end

local function apply_saved_delay(path)
    local per_file, per_dir = delay_paths(path)
    mp.set_property_number('sub-delay', 0)
    if not per_file then return end
    for _, p in ipairs({ per_file, per_dir }) do
        local d = read_delay(p)
        if d then
            mp.set_property_number('sub-delay', d)
            msg.info(('应用字幕偏移 %+.2f 秒: %s'):format(d, p))
            mp.osd_message(('字幕偏移 %+.2f 秒'):format(d), 2)
            return
        end
    end
end

local function save_current_delay(scope)
    local path = mp.get_property('path')
    if not path or path == '' then return end
    local per_file, per_dir = delay_paths(path)
    local target = scope == 'dir' and per_dir or per_file
    local d = current_delay()
    local ok, err = write_delay(target, d)
    if ok then
        mp.osd_message(('已保存字幕偏移 %+.2f 秒'):format(d), 3)
        msg.info('保存字幕偏移: ' .. target)
    else
        mp.osd_message('保存偏移失败: ' .. tostring(err), 4)
    end
end

local function adjust_delay(delta)
    local new = current_delay() + delta
    mp.set_property_number('sub-delay', new)
    mp.osd_message(('字幕偏移 %+.2f 秒'):format(new), 2)
    save_current_delay('file')
end

local exe_cache = {}
local function find_exe(name, fallback)
    if exe_cache[name] then return exe_cache[name] end
    local res = mp.command_native({
        name = 'subprocess',
        args = { 'where.exe', name },
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    })
    if res and res.status == 0 and res.stdout then
        local p = res.stdout:match('([^\r\n]+)')
        if p then
            exe_cache[name] = p
            return p
        end
    end
    local p = fallback or name
    exe_cache[name] = p
    return p
end

local function ziggy_path()
    local p = expand('~~/scripts/uosc/bin/ziggy-windows.exe')
    if not p or not utils.file_info(p) then return nil end
    return p
end

local function run_process(args, cb)
    mp.command_native_async({
        name = 'subprocess',
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, result)
        if not success or not result then
            cb(nil, '子进程启动失败')
            return
        end
        if result.status ~= 0 then
            local err = result.stderr
            if not err or err == '' then err = result.stdout end
            if not err or err == '' then err = '退出码 ' .. tostring(result.status) end
            cb(nil, tostring(err))
            return
        end
        cb(result.stdout or '', nil, result)
    end)
end

local function run_ziggy(args, cb)
    local exe = ziggy_path()
    if not exe then
        cb(nil, '找不到 ziggy 组件')
        return
    end
    local full = { exe }
    for _, a in ipairs(args) do full[#full + 1] = a end
    run_process(full, cb)
end

-- ---------------------------------------------------------------- filename

local RELEASE_TAGS = {
    '2160p', '1080p', '720p', '480p', '360p', '4k', 'uhd',
    'bluray', 'blu%-ray', 'bdrip', 'brrip', 'web%-dl', 'webdl', 'webrip',
    'hdtv', 'hdrip', 'dvdrip', 'remux', 'hdr10%+', 'hdr10', 'hdr', 'dv',
    'x264', 'x265', 'h264', 'h265', 'hevc', 'avc',
    '10bit', '8bit', 'aac', 'ac3', 'eac3', 'dts', 'dtshd', 'truehd',
    'atmos', 'ddp', 'dd5', 'flac', 'opus', 'nf', 'amzn', 'dsnp', 'hmax',
    'itunes',
}

local function clean_name(name)
    if not name or name == '' then return '' end
    name = strip_ext(name)
    name = name:gsub('[%._%+]+', ' ')
    name = name:gsub('[%[%]{}%(%)]', ' ')
    name = name:gsub('【.-】', ' ')
    name = name:lower()
    for _, tag in ipairs(RELEASE_TAGS) do
        name = name:gsub('%f[%w]' .. tag .. '%f[%W]', ' ')
    end
    name = name:gsub('%s+', ' ')
    return (name:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function parse_name(path, media_title)
    local raw = strip_ext(basename(path or ''))
    local lower = raw:lower()

    local season, episode
    season, episode = lower:match('s(%d+)e(%d+)')
    if not season then season, episode = lower:match('(%d+)x(%d+)') end
    if not season then
        local ep = lower:match('第%s*(%d+)%s*集')
        if ep then season, episode = '1', ep end
    end
    season = tonumber(season)
    episode = tonumber(episode)

    local year = raw:match('%f[%d]19%d%d%f[%D]') or raw:match('%f[%d]20%d%d%f[%D]')
    if not year then year = raw:match('19%d%d') or raw:match('20%d%d') end

    local title
    if season then
        local cut = lower:find('s%d+e%d+') or lower:find('%d+x%d+') or lower:find('第%s*%d+%s*集')
        local title_raw = cut and raw:sub(1, cut - 1) or raw
        title = clean_name(title_raw)
        if year then title = title:gsub('%s*' .. year .. '%s*', ' ') end
    else
        title = clean_name(raw)
        if year then title = title:gsub('%s*' .. year .. '%s*', ' ') end
    end
    title = title:gsub('%s*[-–—]+%s*$', '')
    title = title:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    if media_title and media_title ~= '' then
        local mt = clean_name(media_title)
        if mt ~= title and #mt > 2 and not mt:find('^%s*$') then
            -- 有些文件 media-title 就是文件名，避免重复；这里只在明显不同时用
            if not mt:find(title, 1, true) then
                -- 不覆盖，保留文件名标题更可靠
            end
        end
    end

    -- 搜索用完整标题即可（保留 US/UK 等后缀，避免误删 The Last of Us 这类标题）
    local simple_title = title

    return {
        raw = raw,
        title = title,
        simple_title = simple_title,
        dot_title = title:gsub('%s+', '.'),
        space_title = title,
        year = tonumber(year),
        season = season,
        episode = episode,
        ep_tag = (season and episode) and string.format('S%02dE%02d', season, episode) or nil,
        season_tag = season and string.format('S%02d', season) or nil,
        video_base = strip_ext(basename(path or '')),
    }
end

-- ---------------------------------------------------------------- OpenSubtitles

local function os_search(info, cb)
    local params = {
        'languages=' .. url_encode(o.languages),
        'page=1',
        'query=' .. url_encode(info.simple_title),
    }
    if info.season and info.episode then
        params[#params + 1] = 'season_number=' .. tostring(info.season)
        params[#params + 1] = 'episode_number=' .. tostring(info.episode)
        params[#params + 1] = 'type=episode'
    else
        params[#params + 1] = 'type=movie'
        if info.year then params[#params + 1] = 'year=' .. tostring(info.year) end
    end
    local url = 'https://api.opensubtitles.com/api/v1/subtitles?' .. table.concat(params, '&')
    local headers = utils.format_json({
        ['Api-Key'] = o.api_key,
        ['User-Agent'] = o.agent,
        ['Accept'] = 'application/json',
    })
    msg.info('OpenSubtitles 查询: ' .. url)
    run_ziggy({ 'http-get', '--headers', headers, url }, function(stdout, err)
        if not stdout then
            cb(nil, err)
            return
        end
        local resp = utils.parse_json(stdout)
        if not resp then
            cb(nil, 'OpenSubtitles 返回异常')
            return
        end
        if resp.status and resp.status ~= 200 then
            local body = resp.body and utils.parse_json(resp.body)
            local m = body and (body.message or body.error)
            cb(nil, ('OpenSubtitles HTTP %s%s'):format(tostring(resp.status), m and (' - ' .. tostring(m)) or ''))
            return
        end
        local data = resp.body and utils.parse_json(resp.body)
        if not data or type(data.data) ~= 'table' then
            cb(nil, 'OpenSubtitles 数据异常')
            return
        end
        cb(data.data, nil)
    end)
end

local function os_matches(a, info)
    local fd = a.feature_details
    if fd then
        local st = (info.simple_title or ''):lower()
        local parent = (fd.parent_title or ''):lower()
        local movie = (fd.movie_name or ''):lower()
        local title = (fd.title or ''):lower()
        local hay = parent .. ' ' .. movie .. ' ' .. title
        if st ~= '' and (hay:find(st, 1, true) or (parent ~= '' and st:find(parent, 1, true))) then
            return true
        end
        return false
    end
    -- 没有 feature 信息时，看 release 是否带季集
    if info.ep_tag and a.release and a.release:lower():find(info.ep_tag:lower(), 1, true) then
        return true
    end
    return not info.season
end

local function filter_os_results(results, info)
    local list = {}
    for _, sub in ipairs(results) do
        local a = sub.attributes
        if a and a.language and a.files and a.files[1] and os_matches(a, info) then
            list[#list + 1] = sub
        end
    end
    return list
end

local function score_os(a, info)
    local lang = (a.language or ''):lower()
    local score = (lang == 'zh-cn' or lang == 'zh-hans' or lang == 'zh' or lang == 'chi') and 3000
        or (lang == 'zh-tw' or lang == 'zh-hant') and 2000 or 1000
    local release = (a.release or ''):lower()
    if info.ep_tag and release:find(info.ep_tag:lower(), 1, true) then score = score + 500 end
    if a.from_trusted then score = score + 100 end
    if a.hd then score = score + 20 end
    score = score + math.min((a.download_count or 0) / 100, 99)
    return score
end

local function show_os_results(results, info, dest)
    local scored = {}
    for _, sub in ipairs(results) do
        scored[#scored + 1] = { sub = sub, score = score_os(sub.attributes, info) }
    end
    table.sort(scored, function(x, y) return x.score > y.score end)

    local items = {}
    for i = 1, math.min(#scored, o.max_items) do
        local a = scored[i].sub.attributes
        local release = a.release or '未知字幕'
        local lang = a.language or ''
        local hint = ('OpenSubtitles · %s · %s 次下载'):format(lang, tostring(a.download_count or 0))
        items[#items + 1] = {
            title = release,
            hint = hint,
            value = { source = 'opensubtitles', file_id = a.files[1].file_id, release = release, lang = lang },
            keep_open = false,
        }
    end

    items[#items + 1] = {
        title = '从 Assrt 再搜一次（中文字幕站）',
        icon = 'search',
        value = 'script-message-to subs_cn assrt-fallback',
        keep_open = false,
    }

    active_dest = dest
    active_episode = info.ep_tag
    active_video_base = info.video_base
    open_menu({
        type = 'subs_cn-results',
        title = '中文字幕搜索结果',
        search_style = 'disabled',
        items = items,
        callback = { 'subs_cn', 'menu-event' },
        footnote = ('OpenSubtitles · %s · 点击条目下载并加载 · Esc 取消'):format(info.simple_title),
    })
end

-- ---------------------------------------------------------------- Assrt

local function assrt_search(query, cb)
    local curl = find_exe('curl', 'C:/Windows/System32/curl.exe')
    local url = 'https://assrt.net/sub/?searchword=' .. url_encode(query)
    msg.info('Assrt 搜索: ' .. url)
    run_process({
        curl, '-fsL', '--max-time', '25',
        '-A', UA, '-e', 'https://assrt.net/',
        url,
    }, function(html, err)
        if not html then
            cb(nil, err)
            return
        end
        cb(html, nil)
    end)
end

local function rank_assrt_filename(lname, info)
    -- 文件名里带具体集数：只接受当前集，别的集直接淘汰
    local es, ee = lname:match('s(%d+)e(%d+)')
    if es and ee then
        if info.season and info.episode
            and tonumber(es) == info.season and tonumber(ee) == info.episode then
            return 1
        end
        return 9
    end

    -- 季数范围：S01-S09
    local ra, rb = lname:match('s(%d+)%s*%-%s*s(%d+)')
    if ra and rb and info.season
        and info.season >= tonumber(ra) and info.season <= tonumber(rb) then
        return 2
    end

    -- 单个季：S07 / 第7季
    if info.season then
        local ss = lname:match('s(%d+)')
        local cn = lname:match('第(%d+)季')
        local found = tonumber(ss or cn)
        if found then
            return found == info.season and 2 or 9
        end
    end

    return info.season and 5 or 1
end

local function parse_assrt_links(html, info)
    local by_url, list = {}, {}
    for link in html:gmatch("['\"](/download/[^'\"]+%.zip)['\"]") do
        if not by_url[link] then
            by_url[link] = true
            local filename = url_decode(link:match('/([^/]+)$') or '')
            local rank = rank_assrt_filename(filename:lower(), info)
            list[#list + 1] = {
                url = 'https://assrt.net' .. link,
                filename = filename,
                rank = rank,
            }
        end
    end
    table.sort(list, function(x, y)
        if x.rank ~= y.rank then return x.rank < y.rank end
        return #x.filename < #y.filename
    end)
    return list
end

local function copy_subtitle_to_dest(src, dest, video_base)
    local ext = src:match('%.([%a]+)$') or 'ass'
    local target = utils.join_path(dest, video_base .. '.chs.' .. ext)
    local content = read_file(src)
    if content and write_file(target, content) then
        return target
    end
    local alt_dir = expand('~~/subtitles')
    local alt = utils.join_path(alt_dir, video_base .. '.chs.' .. ext)
    content = content or read_file(src)
    if content and write_file(alt, content) then
        return alt
    end
    return nil
end

local function load_assrt(link, info, dest, cb)
    local id = link.url:match('/download/(%d+)/') or tostring(os.time())
    local cache_root = expand('~~/cache/subs_cn')
    local out_dir = utils.join_path(cache_root, 'assrt_' .. id)
    local clean_dir = utils.join_path(out_dir, 'clean')

    -- 缓存命中：不再下载
    if info.ep_tag then
        for _, ext in ipairs({ '.ass', '.ssa', '.srt' }) do
            local cached = utils.join_path(clean_dir, info.ep_tag .. ext)
            if utils.file_info(cached) then
                msg.info('Assrt 缓存命中: ' .. cached)
                local target = copy_subtitle_to_dest(cached, dest, info.video_base)
                if target then
                    cb(target, nil)
                else
                    cb(nil, '写入视频目录失败')
                end
                return
            end
        end
    end

    local curl = find_exe('curl', 'C:/Windows/System32/curl.exe')
    local zip_path = utils.join_path(expand('~~/cache'), 'subs_cn_' .. id .. '.zip')
    msg.info('下载 Assrt 字幕包: ' .. link.url)
    mp.osd_message('正在下载字幕包…', 3)

    run_process({
        curl, '-fsL', '--max-time', '180',
        '-A', UA, '-e', 'https://assrt.net/',
        '-o', zip_path, link.url,
    }, function(_, err)
        if err then
            cb(nil, err)
            return
        end

        mp.osd_message('正在解压字幕…', 3)
        local ps1 = expand('~~/subs_cn/assrt_extract.ps1')
        local target_base = utils.join_path(dest, info.video_base .. '.chs')
        run_process({
            'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ps1,
            '-Zip', zip_path,
            '-OutDir', out_dir,
            '-Episode', info.ep_tag or '',
            '-Season', info.season_tag or '',
            '-TargetBase', target_base,
        }, function(stdout, perr)
            os.remove(zip_path)
            if perr then
                cb(nil, perr)
                return
            end
            local target = stdout and stdout:match('OK:([^\r\n]+)')
            if not target or not utils.file_info(target) then
                cb(nil, '解压后没有找到字幕文件')
                return
            end
            cb(target, nil)
        end)
    end)
end

local function assrt_find(info, dest, cb)
    local queries = {}
    if info.season and info.episode then
        queries[#queries + 1] = info.dot_title .. '.' .. info.ep_tag
        queries[#queries + 1] = info.dot_title .. '.' .. info.season_tag
        queries[#queries + 1] = info.space_title .. ' ' .. info.ep_tag
        queries[#queries + 1] = info.dot_title
    else
        if info.year then queries[#queries + 1] = info.dot_title .. '.' .. info.year end
        queries[#queries + 1] = info.dot_title
        queries[#queries + 1] = info.space_title
    end

    local index = 0
    local last_url = nil
    local function next_query()
        index = index + 1
        local query = queries[index]
        if not query then
            cb(nil, nil, last_url)
            return
        end

        local function try_query(q, is_retry)
            mp.osd_message('Assrt 搜索中…\n' .. q, 2)
            assrt_search(q, function(html, err)
                if err then
                    if not is_retry then
                        msg.warn('Assrt 搜索失败，1 秒后重试: ' .. tostring(err))
                        mp.add_timeout(1.0, function() try_query(q, true) end)
                        return
                    end
                    msg.warn('Assrt 搜索失败: ' .. tostring(err))
                    mp.add_timeout(0.4, next_query)
                    return
                end

                last_url = 'https://assrt.net/sub/?searchword=' .. url_encode(q)
                local all_links = parse_assrt_links(html, info)
                local links = {}
                for _, l in ipairs(all_links) do
                    -- 电视剧只接受当前集或当前季/整剧包；电影接受所有结果
                    if l.rank < 9 and (not info.season or l.rank <= 2) then
                        links[#links + 1] = l
                    end
                end
                if #links == 0 then
                    msg.info('Assrt 无结果（或只有集数/季数不匹配的包）: ' .. q)
                    mp.add_timeout(0.4, next_query)
                    return
                end

                local link = links[1]
                msg.info(('Assrt 选中: rank=%d %s'):format(link.rank, link.filename))
                load_assrt(link, info, dest, function(target, derr)
                    if target then
                        cb(target, nil, last_url)
                    else
                        msg.error('Assrt 下载/解压失败: ' .. tostring(derr))
                        mp.add_timeout(0.4, next_query)
                    end
                end)
            end)
        end

        try_query(query, false)
    end
    next_query()
end

-- ---------------------------------------------------------------- UI

function open_menu(data)
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(data))
end

local function show_empty(info, assrt_url)
    active_dest = nil
    active_assrt_url = assrt_url
    local tried = info.ep_tag and (info.simple_title .. ' ' .. info.ep_tag) or info.simple_title
    open_menu({
        type = 'subs_cn-empty',
        title = '没有找到中文字幕',
        search_style = 'disabled',
        items = {
            {
                title = '在浏览器打开 Assrt 搜索',
                value = 'script-message-to subs_cn open-assrt',
                icon = 'open_in_new',
            },
            {
                title = '手动搜索（可自己改片名）',
                value = 'script-binding uosc/download-subtitles',
                icon = 'search',
            },
            {
                title = '已尝试: ' .. tried,
                selectable = false,
                muted = true,
                italic = true,
                align = 'center',
            },
        },
        footnote = 'Assrt 搜索页会自动打开，可手动挑选字幕　·　Esc 关闭',
    })
end

-- ---------------------------------------------------------------- main

local function find()
    msg.info('subs_cn/find 被触发')
    if busy then
        mp.osd_message('正在搜索中，请稍候…', 2)
        return
    end

    local path = mp.get_property('path')
    if not path or path == '' then
        mp.osd_message('没有正在播放的文件', 3)
        return
    end

    local info = parse_name(path, mp.get_property('media-title') or '')
    local dest = is_url(path) and expand('~~/subtitles') or dirname(path)
    active_dest = dest
    active_episode = info.ep_tag
    active_video_base = info.video_base
    active_info = info

    msg.info(('解析: raw=[%s] title=[%s] year=%s season=%s episode=%s'):format(
        info.raw, info.title, tostring(info.year), tostring(info.season), tostring(info.episode)))

    if info.simple_title == '' then
        mp.osd_message('无法从文件名解析片名', 4)
        return
    end

    busy = true
    mp.osd_message('正在搜索中文字幕…', 2)

    os_search(info, function(results, err)
        if err then
            msg.warn('OpenSubtitles 搜索失败: ' .. tostring(err))
            -- 接口失败也继续尝试 Assrt
            results = {}
        end

        local filtered = filter_os_results(results or {}, info)
        if #filtered > 0 then
            busy = false
            msg.info(('OpenSubtitles 命中 %d 条'):format(#filtered))
            show_os_results(filtered, info, dest)
            return
        end

        if not o.use_assrt then
            busy = false
            show_empty(info, nil)
            return
        end

        msg.info('OpenSubtitles 没有中文结果，改用 Assrt')
        mp.osd_message('OpenSubtitles 无中文，正在搜索 Assrt…', 3)
        assrt_find(info, dest, function(target, derr, last_url)
            busy = false
            if target then
                mp.commandv('sub-add', target, 'select')
                mp.osd_message('已加载中文字幕\n' .. basename(target) .. '\n不同步：Alt+Z 延迟 / Alt+X 提前', 6)
                msg.info('字幕已加载: ' .. target)
            else
                if derr then msg.error('Assrt 失败: ' .. tostring(derr)) end
                show_empty(info, last_url)
            end
        end)
    end)
end

-- 结果菜单点击（OpenSubtitles）
mp.register_script_message('menu-event', function(json)
    local event = utils.parse_json(json)
    if not event or event.type ~= 'activate' or not event.value then return end
    local v = event.value
    if type(v) ~= 'table' or v.source ~= 'opensubtitles' or not v.file_id then return end

    local dest = active_dest
    if not dest then return end

    mp.commandv('script-message-to', 'uosc', 'close-menu', 'subs_cn-results')
    mp.osd_message(('正在下载字幕…\n[%s] %s'):format(v.lang or '', v.release or ''), 4)

    run_ziggy({
        'download-subtitles',
        '--api-key', o.api_key,
        '--agent', o.agent,
        '--file-id', tostring(v.file_id),
        '--destination', dest,
    }, function(stdout, err)
        if not stdout then
            msg.error('字幕下载失败: ' .. tostring(err))
            mp.osd_message('字幕下载失败: ' .. tostring(err), 6)
            return
        end
        local data = utils.parse_json(stdout)
        if not data or not data.file then
            mp.osd_message('字幕下载失败', 6)
            return
        end
        mp.commandv('sub-add', data.file, 'select')
        local extra = data.remaining ~= nil and ('\n今日剩余下载次数: ' .. tostring(data.remaining)) or ''
        mp.osd_message(('已加载字幕\n[%s] %s%s\n不同步：Alt+Z 延迟 / Alt+X 提前'):format(v.lang or '', v.release or '', extra), 6)
        msg.info('字幕已加载: ' .. data.file)
    end)
end)

-- 从 OpenSubtitles 结果菜单转去 Assrt
mp.register_script_message('assrt-fallback', function()
    if busy or not active_info or not active_dest then return end
    busy = true
    mp.commandv('script-message-to', 'uosc', 'close-menu', 'subs_cn-results')
    mp.osd_message('正在从 Assrt 搜索中文字幕…', 2)
    assrt_find(active_info, active_dest, function(target, derr, last_url)
        busy = false
        if target then
            mp.commandv('sub-add', target, 'select')
            mp.osd_message('已加载中文字幕\n' .. basename(target) .. '\n不同步：Alt+Z 延迟 / Alt+X 提前', 6)
            msg.info('字幕已加载: ' .. target)
        else
            if derr then msg.error('Assrt 失败: ' .. tostring(derr)) end
            show_empty(active_info, last_url)
        end
    end)
end)

-- 空结果菜单：打开 Assrt 搜索页
mp.register_script_message('open-assrt', function()
    if not active_assrt_url then return end
    run_ziggy({ 'open', active_assrt_url }, function() end)
end)

-- 字幕偏移：打开文件时自动应用；Alt+Z/Alt+X 调整并保存
mp.register_event('file-loaded', function()
    apply_saved_delay(mp.get_property('path'))
end)

mp.register_script_message('delay-up', function(arg)
    adjust_delay(tonumber(arg) or 1.0)
end)
mp.register_script_message('delay-down', function(arg)
    adjust_delay(-(tonumber(arg) or 1.0))
end)
mp.register_script_message('delay-reset', function()
    mp.set_property_number('sub-delay', 0)
    mp.osd_message('字幕偏移 0.00 秒', 2)
    save_current_delay('file')
end)
mp.register_script_message('save-delay', function()
    save_current_delay('file')
end)
mp.register_script_message('save-delay-dir', function()
    save_current_delay('dir')
end)

-- 注册脚本命令 subs_cn/find；Ctrl+D 的按键绑定在 input.conf
mp.add_key_binding(nil, 'find', find)

-- 调试：查看文件名解析结果
mp.add_key_binding(nil, 'debug-info', function()
    local path = mp.get_property('path') or ''
    local info = parse_name(path, mp.get_property('media-title') or '')
    local text = ('title=%s | simple=%s | year=%s | S=%s E=%s | ep=%s | dot=%s'):format(
        info.title, info.simple_title, tostring(info.year), tostring(info.season),
        tostring(info.episode), tostring(info.ep_tag), info.dot_title)
    msg.info('SUBS_CN_DEBUG: ' .. text)
    mp.osd_message('解析: ' .. text, 8)
end)
