local M = {}

local function trim(value)
  if value == nil then return nil end
  return tostring(value):match '^%s*(.-)%s*$'
end

local cfg = {
  url = os.getenv 'FRESHRSS_URL',
  login = os.getenv 'FRESHRSS_LOGIN',
  password = os.getenv 'FRESHRSS_PASSWORD',
  timeout = 30000,
  cache_ttl = 60,
  page_size = 50,
  feed_fetch_max_pages = 20,
  keymap = {
    open = 'o',
    copy = 'y',
    read = 'r',
    toggle_saved = 's',
    refresh = 'R',
  },
}

function M.setup(opt)
  cfg = lc.tbl_deep_extend('force', cfg, opt or {})
  cfg.url = trim(cfg.url)
  cfg.login = trim(cfg.login)
  cfg.password = trim(cfg.password)
  cfg.api_endpoint = require('freshrss.greader').normalize_api_url(cfg.url)
  cfg.client_login_endpoint = cfg.api_endpoint and (cfg.api_endpoint .. '/accounts/ClientLogin') or nil
  cfg.reader_api_endpoint = cfg.api_endpoint and (cfg.api_endpoint .. '/reader/api/0') or nil
end

function M.get() return cfg end

function M.ready()
  return cfg.api_endpoint and cfg.login and cfg.password
end

return M
