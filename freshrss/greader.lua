local M = {}
local CACHE_NAMESPACE = 'freshrss'

local function trim(s)
  if not s then return nil end
  return tostring(s):match '^%s*(.-)%s*$'
end

local function ends_with(s, suffix)
  if suffix == '' then return true end
  return s:sub(-#suffix) == suffix
end

function M.normalize_api_url(url)
  url = trim(url)
  if not url or url == '' then return nil end
  url = url:gsub('/+$', '')

  if ends_with(url, '/api/greader.php') or ends_with(url, '/greader.php') then return url end
  if ends_with(url, '/api/fever.php') then return url:gsub('/api/fever%.php$', '/api/greader.php') end
  if ends_with(url, '/fever.php') then return url:gsub('/fever%.php$', '/greader.php') end
  if ends_with(url, '/api') then return url .. '/greader.php' end
  return url .. '/api/greader.php'
end

local function urlencode(value)
  return tostring(value):gsub('\n', '\r\n'):gsub('([^%w%-_%.~])', function(char)
    return string.format('%%%02X', string.byte(char))
  end)
end

local function encode_pairs(pairs)
  local chunks = {}
  for _, pair in ipairs(pairs or {}) do
    if pair[2] ~= nil then
      table.insert(chunks, urlencode(pair[1]) .. '=' .. urlencode(pair[2]))
    end
  end
  return table.concat(chunks, '&')
end

local function encode_query(params)
  local chunks = {}
  for key, value in pairs(params or {}) do
    if value ~= nil and value ~= '' then
      table.insert(chunks, urlencode(key) .. '=' .. urlencode(value))
    end
  end
  table.sort(chunks)
  return table.concat(chunks, '&')
end

local function parse_feed_id(stream_id)
  local feed_id = tostring(stream_id or ''):match('^feed/(.+)$')
  return feed_id and tonumber(feed_id) or nil
end

local function has_category(item, category)
  for _, value in ipairs(item.categories or {}) do
    if value == category then return true end
  end
  return false
end

local function item_url(item)
  if item.alternate and item.alternate[1] and item.alternate[1].href then
    return item.alternate[1].href
  end
  if item.canonical and item.canonical[1] and item.canonical[1].href then
    return item.canonical[1].href
  end
  return ''
end

local function item_html(item)
  if item.content and item.content.content then return item.content.content end
  if item.summary and item.summary.content then return item.summary.content end
  return ''
end

local function sort_items_desc(items)
  table.sort(items, function(a, b) return tonumber(a.id or 0) > tonumber(b.id or 0) end)
  return items
end

function M.create(opts)
  local cfg = opts.cfg
  local state = opts.state
  local cache_key = opts.cache_key

  local client = {}

  local function ensure_ready()
    return cfg.api_endpoint and cfg.login and cfg.password
  end

  local function request(req_opts, cb)
    lc.http.request({
      url = req_opts.url,
      method = req_opts.method or 'GET',
      headers = req_opts.headers,
      body = req_opts.body,
      timeout = cfg.timeout,
    }, function(response)
      if not response.success then
        cb(nil, response.error or ('HTTP ' .. tostring(response.status)), response.status)
        return
      end
      cb(response.body, nil, response.status)
    end)
  end

  local function ensure_auth(cb)
    if state.auth then
      cb(state.auth)
      return
    end

    request({
      url = cfg.client_login_endpoint,
      method = 'POST',
      headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
      },
      body = encode_pairs {
        { 'Email', cfg.login },
        { 'Passwd', cfg.password },
      },
    }, function(body, err)
      if err then
        cb(nil, err)
        return
      end

      local auth = tostring(body or ''):match('\nAuth=([^\n]+)') or tostring(body or ''):match('^Auth=([^\n]+)')
      if not auth then
        cb(nil, 'FreshRSS greader login failed')
        return
      end

      state.auth = auth
      cb(auth)
    end)
  end

  local function with_auth_request(req_opts, cb, retrying)
    if not ensure_ready() then
      cb(nil, 'FreshRSS is not configured')
      return
    end

    ensure_auth(function(auth, auth_err)
      if not auth then
        cb(nil, auth_err or 'FreshRSS greader auth failed')
        return
      end

      local headers = {}
      for key, value in pairs(req_opts.headers or {}) do
        headers[key] = value
      end
      headers.Authorization = 'GoogleLogin auth=' .. auth

      request({
        url = req_opts.url,
        method = req_opts.method,
        headers = headers,
        body = req_opts.body,
      }, function(body, err, status)
        if err and status == 401 and not retrying then
          state.auth = nil
          state.edit_token = nil
          with_auth_request(req_opts, cb, true)
          return
        end
        cb(body, err, status)
      end)
    end)
  end

  local function json_get(path, params, cb)
    local query = encode_query(params)
    local url = cfg.reader_api_endpoint .. path
    if query ~= '' then url = url .. '?' .. query end

    with_auth_request({
      url = url,
      method = 'GET',
    }, function(body, err)
      if err then
        cb(nil, err)
        return
      end

      local ok, data = pcall(lc.json.decode, body or '')
      if not ok then
        cb(nil, 'invalid JSON response')
        return
      end
      cb(data)
    end)
  end

  local function ensure_edit_token(cb)
    if state.edit_token then
      cb(state.edit_token)
      return
    end

    with_auth_request({
      url = cfg.reader_api_endpoint .. '/token',
      method = 'GET',
    }, function(body, err)
      if err then
        cb(nil, err)
        return
      end

      local token = trim(body)
      if not token or token == '' then
        cb(nil, 'failed to get greader edit token')
        return
      end
      state.edit_token = token
      cb(token)
    end)
  end

  function client.invalidate_auth()
    state.auth = nil
    state.edit_token = nil
  end

  function client.normalize_item(item)
    return {
      id = tonumber(item.timestampUsec or item.crawlTimeMsec or 0),
      api_id = item.id,
      feed_id = parse_feed_id(item.origin and item.origin.streamId),
      title = item.title or '',
      author = item.author or '',
      html = item_html(item),
      url = item_url(item),
      is_saved = has_category(item, 'user/-/state/com.google/starred'),
      is_read = has_category(item, 'user/-/state/com.google/read'),
      created_on_time = tonumber(item.published or 0),
    }
  end

  function client.fetch_feeds(cb)
    local key = cache_key 'feeds'
    local cached = lc.cache.get(CACHE_NAMESPACE, key)
    if cached ~= nil then
      cb(cached)
      return
    end

    json_get('/subscription/list', { output = 'json' }, function(subscriptions, sub_err)
      if sub_err then
        cb(nil, sub_err)
        return
      end

      json_get('/unread-count', { output = 'json' }, function(unread_counts, unread_err)
        if unread_err then
          cb(nil, unread_err)
          return
        end

        local unread_by_id = {}
        local newest_by_id = {}
        for _, row in ipairs(unread_counts.unreadcounts or {}) do
          unread_by_id[row.id] = tonumber(row.count) or 0
          newest_by_id[row.id] = tonumber(row.newestItemTimestampUsec or 0) or 0
        end

        local feeds = {}
        local by_id = {}
        local group_title_by_feed = {}
        for _, feed in ipairs(subscriptions.subscriptions or {}) do
          local id = parse_feed_id(feed.id)
          if id then
            local category = feed.categories and feed.categories[1] or nil
            local group_title = category and category.label or nil
            local newest_usec = newest_by_id[feed.id] or 0
            local row = {
              id = id,
              title = feed.title,
              url = feed.url,
              site_url = feed.htmlUrl,
              icon_url = feed.iconUrl,
              group_title = group_title,
              unread_count = unread_by_id[feed.id] or 0,
              last_updated_on_time = newest_usec > 0 and math.floor(newest_usec / 1000000) or nil,
            }
            table.insert(feeds, row)
            by_id[tostring(id)] = row
            group_title_by_feed[tostring(id)] = group_title
          end
        end

        local result = {
          feeds = feeds,
          by_id = by_id,
          group_title_by_feed = group_title_by_feed,
          unread_total = unread_by_id['user/-/state/com.google/reading-list'] or 0,
        }
        lc.cache.set(CACHE_NAMESPACE, key, result, { ttl = cfg.cache_ttl })
        cb(result)
      end)
    end)
  end

  function client.fetch_stream_item_count(stream_id, params, cb)
    local key = cache_key('count:' .. stream_id)
    local cached = lc.cache.get(CACHE_NAMESPACE, key)
    if cached ~= nil then
      cb(cached)
      return
    end

    local count = 0
    local function fetch_page(page, continuation)
      local query = { s = stream_id, n = 1000 }
      for k, v in pairs(params or {}) do
        query[k] = v
      end
      if continuation then query.c = continuation end

      json_get('/stream/items/ids', query, function(data, err)
        if err then
          cb(nil, err)
          return
        end

        count = count + #(data.itemRefs or {})
        if not data.continuation or page >= cfg.feed_fetch_max_pages then
          lc.cache.set(CACHE_NAMESPACE, key, count, { ttl = cfg.cache_ttl })
          cb(count)
          return
        end
        fetch_page(page + 1, data.continuation)
      end)
    end

    fetch_page(1)
  end

  function client.fetch_stream_items(cache_name, path, params, max_pages, cb)
    local key = cache_key(cache_name)
    local cached = lc.cache.get(CACHE_NAMESPACE, key)
    if cached ~= nil then
      cb(cached)
      return
    end

    local all_items = {}
    local seen = {}

    local function fetch_page(page, continuation)
      local query = { n = cfg.page_size }
      for k, v in pairs(params or {}) do
        query[k] = v
      end
      if continuation then query.c = continuation end

      json_get(path, query, function(data, err)
        if err then
          cb(nil, err)
          return
        end

        for _, item in ipairs(data.items or {}) do
          local normalized = client.normalize_item(item)
          if normalized.id and not seen[normalized.id] then
            seen[normalized.id] = true
            table.insert(all_items, normalized)
          end
        end

        if not data.continuation or page >= max_pages then
          all_items = sort_items_desc(all_items)
          lc.cache.set(CACHE_NAMESPACE, key, all_items, { ttl = cfg.cache_ttl })
          cb(all_items)
          return
        end
        fetch_page(page + 1, data.continuation)
      end)
    end

    fetch_page(1)
  end

  function client.fetch_feed_items(feed_id, cb)
    client.fetch_stream_items('feed_items:' .. tostring(feed_id), '/stream/contents/feed/' .. tostring(feed_id), nil, cfg.feed_fetch_max_pages, cb)
  end

  function client.edit_tag(item_ids, adds, removes, cb)
    ensure_edit_token(function(token, token_err)
      if not token then
        cb(nil, token_err)
        return
      end

      local form = { { 'T', token } }
      for _, item_id in ipairs(item_ids or {}) do
        table.insert(form, { 'i', item_id })
      end
      for _, tag in ipairs(adds or {}) do
        table.insert(form, { 'a', tag })
      end
      for _, tag in ipairs(removes or {}) do
        table.insert(form, { 'r', tag })
      end

      with_auth_request({
        url = cfg.reader_api_endpoint .. '/edit-tag',
        method = 'POST',
        headers = {
          ['Content-Type'] = 'application/x-www-form-urlencoded',
        },
        body = encode_pairs(form),
      }, function(body, err, status)
        if err and status == 401 then state.edit_token = nil end
        if err then
          cb(nil, err)
          return
        end
        cb(trim(body or 'OK'))
      end)
    end)
  end

  return client
end

return M
