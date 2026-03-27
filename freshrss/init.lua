local GReader = require 'freshrss.greader'

local M = {}

local cfg = {
  url = os.getenv 'FRESHRSS_URL',
  login = os.getenv 'FRESHRSS_LOGIN',
  password = os.getenv 'FRESHRSS_PASSWORD',
  timeout = 30000,
  cache_ttl = 60,
  page_size = 50,
  feed_fetch_max_pages = 20,
}

local state = {
  auth = nil,
  edit_token = nil,
  cache_version = 0,
  page_entries = {},
}

local CACHE_PREFIX = 'freshrss:'
local greader
local item_display
local article_preview
local section_preview

local function trim(s)
  if not s then return nil end
  return tostring(s):match '^%s*(.-)%s*$'
end

local function decode_html_entities(text)
  if not text then return '' end
  local entities = {
    ['&nbsp;'] = ' ',
    ['&amp;'] = '&',
    ['&lt;'] = '<',
    ['&gt;'] = '>',
    ['&quot;'] = '"',
    ['&#39;'] = "'",
  }
  text = text:gsub('&#x([%da-fA-F]+);', function(hex)
    local code = tonumber(hex, 16)
    return code and utf8.char(code) or ''
  end)
  text = text:gsub('&#(%d+);', function(dec)
    local code = tonumber(dec)
    return code and utf8.char(code) or ''
  end)
  for entity, replacement in pairs(entities) do
    text = text:gsub(entity, replacement)
  end
  return text
end

local function html_to_text(html)
  if not html or html == '' then return '' end
  local text = tostring(html)
  text = text:gsub('<[bB][rR]%s*/?>', '\n')
  text = text:gsub('</[pP]>', '\n\n')
  text = text:gsub('</[hH][1-6]>', '\n\n')
  text = text:gsub('</[lL][iI]>', '\n')
  text = text:gsub('<[lL][iI][^>]*>', '• ')
  text = text:gsub('</[uU][lL]>', '\n')
  text = text:gsub('</[oO][lL]>', '\n')
  text = text:gsub('</[dD][iI][vV]>', '\n')
  text = text:gsub('</[tT][rR]>', '\n')
  text = text:gsub('</[tT][dD]>', ' ')
  text = text:gsub('<script[%s%S]-</script>', '')
  text = text:gsub('<style[%s%S]-</style>', '')
  text = text:gsub('<[^>]+>', '')
  text = decode_html_entities(text)
  text = text:gsub('\r\n', '\n')
  text = text:gsub('\r', '\n')
  text = text:gsub('[ \t]+\n', '\n')
  text = text:gsub('\n[ \t]+', '\n')
  text = text:gsub('\n\n\n+', '\n\n')
  text = text:gsub('[ \t][ \t]+', ' ')
  return text:trim()
end

local function show_error(err)
  lc.notify(lc.style.line {
    lc.style.span('✗ '):fg 'red',
    lc.style.span(tostring(err)):fg 'red',
  })
end

local function invalidate_cache() state.cache_version = state.cache_version + 1 end

local function cache_key(name) return CACHE_PREFIX .. state.cache_version .. ':' .. name end
local function path_key(path) return table.concat(path or {}, '\1') end

local function clone_entry(entry)
  local copied = {}
  for k, v in pairs(entry or {}) do
    if k == 'item' and type(v) == 'table' then
      local item = {}
      for ik, iv in pairs(v) do
        item[ik] = iv
      end
      copied[k] = item
    else
      copied[k] = v
    end
  end
  return copied
end

local function remember_entries(path, entries)
  local copied = {}
  for i, entry in ipairs(entries or {}) do
    copied[i] = clone_entry(entry)
  end
  state.page_entries[path_key(path)] = copied
end

local function entry_index_by_id(entries, id)
  for i, entry in ipairs(entries or {}) do
    if entry.kind == 'item' and tostring(entry.id) == tostring(id) then return i end
  end
end

local function feed_for_entry(entry)
  if not entry or entry.kind ~= 'item' then return nil end
  local feeds = lc.cache.get(cache_key 'feeds')
  return feeds and feeds.by_id and feeds.by_id[tostring(entry.item.feed_id)] or nil
end

local function render_current_page(entries)
  lc.api.page_set_entries(entries)
  local hovered = lc.api.page_get_hovered()
  if not hovered then return end

  if hovered.kind == 'item' then
    local idx = entry_index_by_id(entries, hovered.id)
    if idx then lc.api.page_set_preview(article_preview(entries[idx], feed_for_entry(entries[idx]))) end
    return
  end

  if hovered.kind == 'section' then
    if hovered.key == 'unread' then
      lc.api.page_set_preview(section_preview('Unread', '显示最近的未读文章。'))
      return
    end
    if hovered.key == 'saved' then
      lc.api.page_set_preview(section_preview('Saved', '显示最近收藏的文章。'))
      return
    end
    if hovered.key == 'feeds' then
      lc.api.page_set_preview(section_preview('Feeds', '进入后按订阅源浏览最新文章。'))
      return
    end
  end

  if hovered.kind == 'feed' and hovered.feed then
    local feed = hovered.feed
    lc.api.page_set_preview(
      section_preview(
        feed.title or ('Feed ' .. hovered.key),
        feed.site_url or feed.url or '',
        'Enter 查看该订阅源文章  o 打开站点'
      )
    )
  end
end

local function refresh_entry_display(entry)
  if not entry or entry.kind ~= 'item' then return end
  local feed = feed_for_entry(entry)
  local feed_title = feed and feed.title or ('Feed ' .. tostring(entry.item.feed_id))
  entry.display = item_display(entry.item, feed_title)
end

local function update_entry_locally(id, mutator)
  local current_path = lc.api.get_current_path()
  local entries = state.page_entries[path_key(current_path)]
  if not entries then return nil end

  local idx = entry_index_by_id(entries, id)
  if not idx then return nil end

  local previous = clone_entry(entries[idx])
  mutator(entries[idx])
  refresh_entry_display(entries[idx])
  render_current_page(entries)
  return previous, entries[idx]
end

item_display = function(item, feed_title)
  local read_icon = item.is_read and ' ' or '●'
  local read_color = item.is_read and 'darkgray' or 'cyan'
  local saved_icon = item.is_saved and '★ ' or ''
  local saved_color = item.is_saved and 'yellow' or 'darkgray'
  local title = trim(item.title)
  if not title or title == '' then title = '(no title)' end
  local date = item.created_on_time and lc.time.format(item.created_on_time, 'compact') or ''

  return lc.style.line {
    lc.style.span(read_icon .. ' '):fg(read_color),
    lc.style.span(saved_icon):fg(saved_color),
    lc.style.span(title):fg(item.is_read and 'darkgray' or 'white'),
    lc.style.span('  ' .. (feed_title or '')):fg 'blue',
    lc.style.span('  ' .. date):fg 'darkgray',
  }
end

local function to_item_entry(item, feeds)
  local feed = feeds and feeds.by_id and feeds.by_id[tostring(item.feed_id)] or nil
  local feed_title = feed and feed.title or ('Feed ' .. tostring(item.feed_id))
  return {
    key = tostring(item.id),
    kind = 'item',
    id = item.id,
    item = item,
    url = item.url,
    display = item_display(item, feed_title),
  }
end

local function open_entry(entry)
  if not entry then return end

  if entry.kind == 'item' and entry.url and entry.url ~= '' then
    lc.system.open(entry.url)
    return
  end

  if entry.kind == 'feed' then
    local url = entry.feed and (entry.feed.site_url or entry.feed.url) or nil
    if url and url ~= '' then lc.system.open(url) end
  end
end

local function set_mark(entry, mark)
  if not entry or entry.kind ~= 'item' then return end

  local previous
  if mark == 'read' then
    previous = update_entry_locally(entry.id, function(local_entry) local_entry.item.is_read = true end)
  elseif mark == 'saved' or mark == 'unsaved' then
    previous = update_entry_locally(entry.id, function(local_entry) local_entry.item.is_saved = mark == 'saved' end)
  end

  local adds = {}
  local removes = {}
  if mark == 'read' then
    adds = { 'user/-/state/com.google/read' }
  elseif mark == 'saved' then
    adds = { 'user/-/state/com.google/starred' }
  elseif mark == 'unsaved' then
    removes = { 'user/-/state/com.google/starred' }
  end

  greader.edit_tag({ entry.item.api_id }, adds, removes, function(_, err)
    if err then
      if previous then
        update_entry_locally(entry.id, function(local_entry)
          local_entry.item = previous.item
          local_entry.url = previous.url
        end)
      end
      show_error(err)
      return
    end
    invalidate_cache()
    lc.notify(lc.style.line {
      lc.style.span('✓ '):fg 'green',
      lc.style.span('Updated article state'):fg 'green',
    })
  end)
end

article_preview = function(entry, feed)
  local item = entry.item
  local text = html_to_text(item.html)
  local lines = {
    lc.style.line { lc.style.span(item.title or '(no title)'):fg 'yellow' },
    lc.style.line {
      lc.style.span((feed and feed.title) or ('Feed ' .. tostring(item.feed_id))):fg 'blue',
      lc.style.span('  '):fg 'white',
      lc.style.span(item.created_on_time and lc.time.format(item.created_on_time) or ''):fg 'darkgray',
    },
  }

  if item.author and item.author ~= '' then
    table.insert(
      lines,
      lc.style.line {
        lc.style.span('Author: '):fg 'cyan',
        lc.style.span(item.author):fg 'white',
      }
    )
  end

  table.insert(
    lines,
    lc.style.line {
      lc.style.span('Status: '):fg 'cyan',
      lc.style.span(item.is_read and 'read' or 'unread'):fg(item.is_read and 'darkgray' or 'green'),
      lc.style.span('  saved: '):fg 'cyan',
      lc.style.span(item.is_saved and 'yes' or 'no'):fg(item.is_saved and 'yellow' or 'darkgray'),
    }
  )

  if item.url and item.url ~= '' then
    table.insert(
      lines,
      lc.style.line {
        lc.style.span('URL: '):fg 'cyan',
        lc.style.span(item.url):fg 'magenta',
      }
    )
  end

  table.insert(lines, '')
  table.insert(lines, text ~= '' and text or '(empty content)')
  table.insert(lines, '')
  table.insert(lines, 'Enter/o 打开原文  r 标记已读  s 收藏/取消收藏  y 复制链接')

  return lc.style.text(lines)
end

section_preview = function(title, description, extra)
  local lines = {
    lc.style.line { lc.style.span(title):fg 'yellow' },
    '',
    description,
  }
  if extra and extra ~= '' then
    table.insert(lines, '')
    table.insert(lines, extra)
  end
  return lc.style.text(lines)
end

local function list_root(cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    greader.fetch_stream_item_count('user/-/state/com.google/starred', nil, function(saved_count, saved_err)
      if saved_err then
        cb(nil, saved_err)
        return
      end

      cb {
        {
          key = 'unread',
          kind = 'section',
          display = lc.style.line {
            lc.style.span('● '):fg 'cyan',
            lc.style.span('Unread'):fg 'white',
            lc.style.span('  ' .. tostring(feeds.unread_total or 0)):fg 'darkgray',
          },
        },
        {
          key = 'saved',
          kind = 'section',
          display = lc.style.line {
            lc.style.span('★ '):fg 'yellow',
            lc.style.span('Saved'):fg 'white',
            lc.style.span('  ' .. tostring(saved_count or 0)):fg 'darkgray',
          },
        },
        {
          key = 'feeds',
          kind = 'section',
          display = lc.style.line {
            lc.style.span('≡ '):fg 'green',
            lc.style.span('Feeds'):fg 'white',
            lc.style.span('  ' .. tostring(#(feeds.feeds or {}))):fg 'darkgray',
          },
        },
      }
    end)
  end)
end

local function list_feeds(cb)
  greader.fetch_feeds(function(feeds, err)
    if err then
      cb(nil, err)
      return
    end

    local entries = {}
    for _, feed in ipairs(feeds.feeds or {}) do
      local group_title = feeds.group_title_by_feed[tostring(feed.id)]
      local updated = feed.last_updated_on_time and lc.time.format(feed.last_updated_on_time, 'compact') or ''
      table.insert(entries, {
        key = tostring(feed.id),
        kind = 'feed',
        feed = feed,
        display = lc.style.line {
          lc.style.span(feed.title or ('Feed ' .. tostring(feed.id))):fg 'white',
          lc.style.span(group_title and ('  [' .. group_title .. ']') or ''):fg 'blue',
          lc.style.span(updated ~= '' and ('  ' .. updated) or ''):fg 'darkgray',
        },
      })
    end

    cb(entries)
  end)
end

local function list_virtual_items(kind, cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    local path
    local params = {}
    if kind == 'unread' then
      path = '/stream/contents/reading-list'
      params.xt = 'user/-/state/com.google/read'
    elseif kind == 'saved' then
      path = '/stream/contents/user/-/state/com.google/starred'
    else
      cb(nil, 'unsupported virtual stream')
      return
    end

    greader.fetch_stream_items(kind .. '_items', path, params, 1, function(items, items_err)
      if items_err then
        cb(nil, items_err)
        return
      end

      local entries = {}
      for _, item in ipairs(items) do
        table.insert(entries, to_item_entry(item, feeds))
      end
      cb(entries)
    end)
  end)
end

local function list_feed_articles(feed_id, cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    greader.fetch_feed_items(feed_id, function(items, items_err)
      if items_err then
        cb(nil, items_err)
        return
      end

      local entries = {}
      for _, item in ipairs(items) do
        table.insert(entries, to_item_entry(item, feeds))
      end
      cb(entries)
    end)
  end)
end

function M.setup(opt)
  cfg = lc.tbl_extend('force', cfg, opt or {})
  cfg.login = trim(cfg.login)
  cfg.password = trim(cfg.password)
  cfg.api_endpoint = GReader.normalize_api_url(cfg.url)
  cfg.client_login_endpoint = cfg.api_endpoint and (cfg.api_endpoint .. '/accounts/ClientLogin') or nil
  cfg.reader_api_endpoint = cfg.api_endpoint and (cfg.api_endpoint .. '/reader/api/0') or nil

  state.auth = nil
  state.edit_token = nil
  state.cache_version = 0
  state.page_entries = {}

  greader = GReader.create {
    cfg = cfg,
    state = state,
    cache_key = cache_key,
  }

  lc.keymap.set('main', '<enter>', function()
    local entry = lc.api.page_get_hovered()
    if entry and entry.kind == 'item' then
      open_entry(entry)
    else
      lc.cmd 'enter'
    end
  end)

  lc.keymap.set('main', 'o', function()
    local entry = lc.api.page_get_hovered()
    open_entry(entry)
  end)

  lc.keymap.set('main', 'y', function()
    local entry = lc.api.page_get_hovered()
    if entry and entry.url and entry.url ~= '' then
      lc.osc52_copy(entry.url)
      lc.notify 'Article URL copied'
    end
  end)

  lc.keymap.set('main', 'r', function()
    local entry = lc.api.page_get_hovered()
    if entry and entry.kind == 'item' and not entry.item.is_read then set_mark(entry, 'read') end
  end)

  lc.keymap.set('main', 's', function()
    local entry = lc.api.page_get_hovered()
    if not entry or entry.kind ~= 'item' then return end
    set_mark(entry, entry.item.is_saved and 'unsaved' or 'saved')
  end)

  lc.keymap.set('main', 'R', function()
    invalidate_cache()
    if greader then greader.invalidate_auth() end
    lc.notify 'Refreshing FreshRSS cache...'
    lc.cmd 'reload'
  end)
end

function M.list(path, cb)
  if not (cfg.api_endpoint and cfg.login and cfg.password) then
    cb {
      {
        key = 'configure',
        kind = 'info',
        display = lc.style.line {
          lc.style.span('Configure FreshRSS in setup() or env vars'):fg 'yellow',
        },
      },
    }
    return
  end

  if #path == 0 then
    list_root(function(entries, err)
      if err then
        show_error(err)
        cb {}
        return
      end
      remember_entries(path, entries)
      cb(entries)
    end)
    return
  end

  if path[1] == 'feeds' and #path == 1 then
    list_feeds(function(entries, err)
      if err then
        show_error(err)
        cb {}
        return
      end
      remember_entries(path, entries)
      cb(entries)
    end)
    return
  end

  if path[1] == 'feeds' and #path == 2 then
    list_feed_articles(path[2], function(entries, err)
      if err then
        show_error(err)
        cb {}
        return
      end
      remember_entries(path, entries)
      cb(entries)
    end)
    return
  end

  if path[1] == 'unread' then
    list_virtual_items('unread', function(entries, err)
      if err then
        show_error(err)
        cb {}
        return
      end
      remember_entries(path, entries)
      cb(entries)
    end)
    return
  end

  if path[1] == 'saved' then
    list_virtual_items('saved', function(entries, err)
      if err then
        show_error(err)
        cb {}
        return
      end
      remember_entries(path, entries)
      cb(entries)
    end)
    return
  end

  cb {}
end

function M.preview(entry, cb)
  if not (cfg.api_endpoint and cfg.login and cfg.password) then
    cb(
      section_preview(
        'FreshRSS',
        '请在 setup() 中设置 url/login/password，或导出 FRESHRSS_URL/FRESHRSS_LOGIN/FRESHRSS_PASSWORD。'
      )
    )
    return
  end

  if entry.kind == 'section' then
    if entry.key == 'unread' then
      cb(section_preview('Unread', '显示最近的未读文章。'))
      return
    end
    if entry.key == 'saved' then
      cb(section_preview('Saved', '显示最近收藏的文章。'))
      return
    end
    if entry.key == 'feeds' then
      cb(section_preview('Feeds', '进入后按订阅源浏览最新文章。'))
      return
    end
  end

  if entry.kind == 'feed' then
    local feed = entry.feed
    cb(
      section_preview(
        feed.title or ('Feed ' .. entry.key),
        feed.site_url or feed.url or '',
        'Enter 查看该订阅源文章  o 打开站点'
      )
    )
    return
  end

  if entry.kind == 'item' then
    greader.fetch_feeds(function(feeds) cb(article_preview(entry, feeds.by_id[tostring(entry.item.feed_id)])) end)
    return
  end

  cb(section_preview('FreshRSS', '使用 Enter 进入未读、收藏或订阅源。'))
end

return M
