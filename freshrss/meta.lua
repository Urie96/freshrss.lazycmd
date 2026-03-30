local action = require 'freshrss.action'

local M = {}

local function add_keymap(targets, key, callback, desc)
  if not key or key == '' then return end
  for _, target in ipairs(targets) do
    target[key] = { callback = callback, desc = desc }
  end
end

local metas = {
  section = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        cb(action.section_preview(entry))
      end,
    },
  },
  feed = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        cb(action.feed_preview(entry))
      end,
    },
  },
  item = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        action.item_preview(entry, cb)
      end,
    },
  },
  info = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        if entry.key == 'configure' then
          cb(action.missing_config_preview())
          return
        end
        cb(action.info_preview(entry))
      end,
    },
  },
}

function M.setup(cfg)
  local keymap = (cfg or {}).keymap or {}
  local feed_map = metas.feed.__index.keymap
  local item_map = metas.item.__index.keymap

  for _, map in ipairs({ feed_map, item_map }) do
    for key, _ in pairs(map) do
      map[key] = nil
    end
  end

  add_keymap({ feed_map }, keymap.open, action.open_entry, 'open feed site')

  add_keymap({ item_map }, '<enter>', action.open_entry, 'open article')
  add_keymap({ item_map }, keymap.open, action.open_entry, 'open article')
  add_keymap({ item_map }, keymap.copy, action.copy_url, 'copy article url')
  add_keymap({ item_map }, keymap.read, action.mark_read, 'mark article read')
  add_keymap({ item_map }, keymap.toggle_saved, action.toggle_saved, 'toggle saved')
end

function M.attach(entries)
  for i, entry in ipairs(entries or {}) do
    local mt = metas[entry.kind]
    if mt then entries[i] = setmetatable(entry, mt) end
  end
  return entries
end

return M
