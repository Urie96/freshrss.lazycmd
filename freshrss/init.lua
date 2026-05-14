local action = require 'freshrss.action'
local config = require 'freshrss.config'
local GReader = require 'freshrss.greader'
local meta = require 'freshrss.meta'

local M = {}

local state = {
  auth = nil,
  edit_token = nil,
  cache_version = 0,
  page_entries = {},
}

local CACHE_PREFIX = 'freshrss:'
local greader

local function cache_key(name) return CACHE_PREFIX .. state.cache_version .. ':' .. name end

local function section_entry(key, icon, icon_color, title, count)
  return {
    key = key,
    kind = 'section',
    display = deck.style.line {
      deck.style.span(icon .. ' '):fg(icon_color),
      deck.style.span(title):fg 'white',
      deck.style.span('  ' .. tostring(count or 0)):fg 'darkgray',
    },
  }
end

local function feed_entry(feed, group_title)
  local updated = feed.last_updated_on_time and deck.time.format(feed.last_updated_on_time, 'compact') or ''
  return {
    key = tostring(feed.id),
    kind = 'feed',
    feed = feed,
    url = feed.site_url or feed.url,
    display = deck.style.line {
      deck.style.span(feed.title or ('Feed ' .. tostring(feed.id))):fg 'white',
      deck.style.span(group_title and ('  [' .. group_title .. ']') or ''):fg 'blue',
      deck.style.span(updated ~= '' and ('  ' .. updated) or ''):fg 'darkgray',
    },
  }
end

local function remember(path, entries)
  action.remember_entries(path, entries)
  return entries
end

local function list_root(path, cb)
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

      cb(remember(path, meta.attach {
        section_entry('unread', '●', 'cyan', 'Unread', feeds.unread_total or 0),
        section_entry('saved', '★', 'yellow', 'Saved', saved_count or 0),
        section_entry('feeds', '≡', 'green', 'Feeds', #(feeds.feeds or {})),
      }))
    end)
  end)
end

local function list_feeds(path, cb)
  greader.fetch_feeds(function(feeds, err)
    if err then
      cb(nil, err)
      return
    end

    local entries = {}
    for _, feed in ipairs(feeds.feeds or {}) do
      table.insert(entries, feed_entry(feed, feeds.group_title_by_feed[tostring(feed.id)]))
    end

    cb(remember(path, meta.attach(entries)))
  end)
end

local function list_virtual_items(path, kind, cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    local stream_path
    local params = {}
    if kind == 'unread' then
      stream_path = '/stream/contents/reading-list'
      params.xt = 'user/-/state/com.google/read'
    elseif kind == 'saved' then
      stream_path = '/stream/contents/user/-/state/com.google/starred'
    else
      cb(nil, 'unsupported virtual stream')
      return
    end

    greader.fetch_stream_items(kind .. '_items', stream_path, params, 1, function(items, items_err)
      if items_err then
        cb(nil, items_err)
        return
      end

      local entries = {}
      for _, item in ipairs(items or {}) do
        table.insert(entries, action.to_item_entry(item, feeds))
      end

      cb(remember(path, meta.attach(entries)))
    end)
  end)
end

local function list_feed_articles(path, feed_id, cb)
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
      for _, item in ipairs(items or {}) do
        table.insert(entries, action.to_item_entry(item, feeds))
      end

      cb(remember(path, meta.attach(entries)))
    end)
  end)
end

function M.setup(opt)
  config.setup(opt or {})

  state.auth = nil
  state.edit_token = nil
  state.cache_version = 0
  state.page_entries = {}

  greader = GReader.create {
    cfg = config.get(),
    state = state,
    cache_key = cache_key,
  }

  action.setup {
    cfg = config.get(),
    state = state,
    greader = greader,
    cache_key = cache_key,
  }
  meta.setup(config.get())
end

function M.list(path, cb)
  if not config.ready() then
    cb(meta.attach {
      {
        key = 'configure',
        kind = 'info',
        title = 'FreshRSS',
        message = 'Configure FreshRSS in setup() or env vars',
        detail = 'Set url/login/password or export FRESHRSS_URL/FRESHRSS_LOGIN/FRESHRSS_PASSWORD.',
        color = 'yellow',
      },
    })
    return
  end

  if #path == 1 then
    list_root(path, function(entries, err)
      if err then
        action.show_error(err)
        cb(meta.attach {})
        return
      end
      cb(entries)
    end)
    return
  end

  if path[2] == 'feeds' and #path == 2 then
    list_feeds(path, function(entries, err)
      if err then
        action.show_error(err)
        cb(meta.attach {})
        return
      end
      cb(entries)
    end)
    return
  end

  if path[2] == 'feeds' and #path == 3 then
    list_feed_articles(path, path[3], function(entries, err)
      if err then
        action.show_error(err)
        cb(meta.attach {})
        return
      end
      cb(entries)
    end)
    return
  end

  if path[2] == 'unread' then
    list_virtual_items(path, 'unread', function(entries, err)
      if err then
        action.show_error(err)
        cb(meta.attach {})
        return
      end
      cb(entries)
    end)
    return
  end

  if path[2] == 'saved' then
    list_virtual_items(path, 'saved', function(entries, err)
      if err then
        action.show_error(err)
        cb(meta.attach {})
        return
      end
      cb(entries)
    end)
    return
  end

  cb(meta.attach {})
end

return M
