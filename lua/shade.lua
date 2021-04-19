-- TODO: remove all active_overlays on tab change
local api = vim.api

local E = {}
E.DEFAULT_OVERLAY_OPACITY = 50
E.DEFAULT_OPACITY_STEP    = 10
E.DEBUG_OVERLAY_OPACITY   = 90
E.NOTIFICATION_TIMEOUT    = 1000 -- ms

local state = {}
state.active = false
state.active_overlays = {}
state.shade_nsid          = nil
state.notification_timer  = nil
state.notification_window = nil

-- TODO: log to file
local function log(event, msg)
  if state.debug == false then return end

  msg = tostring(msg)
  local info = debug.getinfo(2, "Sl")
  local line_info = "[shade:" .. info.currentline .. "]"

  local timestamp = ("%s %-15s"):format(os.date("%H:%M:%S"), line_info)
  local event_msg = ("%-10s %s"):format(event, msg)
  print(timestamp .. "  : " .. event_msg)
end

--
local font = {
  0x7C, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0x7C, 0x00,   --  (0)
  0x30, 0x70, 0x30, 0x30, 0x30, 0x30, 0xFC, 0x00,   --  (1)
  0x78, 0xCC, 0x0C, 0x38, 0x60, 0xCC, 0xFC, 0x00,   --  (2)
  0x78, 0xCC, 0x0C, 0x38, 0x0C, 0xCC, 0x70, 0x00,   --  (3)
  0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x1E, 0x00,   --  (4)
  0xFC, 0xC0, 0xF8, 0x0C, 0x0C, 0xCC, 0x78, 0x00,   --  (5)
  0x38, 0x60, 0xC0, 0xF8, 0xCC, 0xCC, 0x78, 0x00,   --  (6)
  0xFC, 0xCC, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00,   --  (7)
  0x78, 0xCC, 0xCC, 0x78, 0xCC, 0xCC, 0x78, 0x00,   --  (8)
  0x78, 0xCC, 0xCC, 0x7C, 0x0C, 0x18, 0x70, 0x00,   --  (9)
}

local function get_digit(number, pos)
  local n  = 10 ^ pos
  local n1 = 10 ^ (pos - 1)
  return math.floor((number % n) / n1)
end

local function digitize(number)
  assert(type(number) == 'number')
  local len = math.floor(math.log10(number)+1)

  local block_chars = {
    [0] = ' ',
    [1] = '▀',
    [2] = '▄',
    [3] = '█'
  }

  -- generate bit table
  local offset, char, row_bits, hex_val, b
  local characters = {}
  for n=1, len do
    offset = get_digit(number, len-n+1) * 8
    char = {}
    for row=1, 8 do
      row_bits = {}
      hex_val = font[offset+row]
      for i=1, 8 do
        b = bit.band(bit.rshift(hex_val, 8-i), 1)
        row_bits[i] = b
      end
      table.insert(char, row_bits)
    end
    table.insert(characters, char)
  end

  -- generate strings
  local output = {}
  local upper, lower, combined, row_str
  for row=1, 8, 2 do
    row_str = ' '
    for _, c in ipairs(characters) do
      for col = 1, 8 do
        upper = c[row][col]
        lower = c[row+1][col] * 2
        combined = block_chars[upper + lower]
        row_str = row_str .. combined
      end
    end
    row_str = row_str .. ' '
    table.insert(output, row_str)
  end

  return output
end

--
local filter_wininfo = function(wininfo)
  return {
    relative  = "editor",
    style     = "minimal",
    focusable = false,
    row       = wininfo.winrow - 1,
    col       = wininfo.wincol - 1,
    width     = wininfo.width,
    height    = wininfo.height,
  }
end

--
local function create_overlay_highlight()
  local overlay_color
  if state.debug == true then
    overlay_color = "#77a992"
  else
    local gui_bg = api.nvim_get_hl_by_name('Normal', true).background
    overlay_color = ("#%x"):format(gui_bg)
  end

  api.nvim_command("highlight shadeOverlay guibg=" .. overlay_color)

  -- Link to default hl_group if not user defined
  local exists, _ = pcall(function() return vim.api.nvim_get_hl_by_name('ShadeBrightnessPopup', false) end)
  if not exists then
    api.nvim_command("highlight link ShadeBrightnessPopup Number")
  end
end

--
local function show_window_metrics(window)
  local wincfg = window.wincfg

  -- show window metrics in virt_text
  local dims_str = ('%d x %d'):format(wincfg.width, wincfg.height)
  local pad = (' '):rep(wincfg.width - #dims_str - 2)
  local virt_text_opts = {
    hl_group      = 'Error',
    virt_text     = {{ pad .. dims_str }},
    virt_text_pos = 'overlay',
    hl_mode       = 'replace'
  }

  -- TODO: why don't the extmarks work?
  api.nvim_buf_clear_namespace(window.bufid, state.shade_nsid, 1, 1)
  api.nvim_buf_set_extmark(window.bufid, state.shade_nsid, 1, 0, virt_text_opts)
end

local function map_key(mode, key, action)
  local req_module = ("<cmd>lua require'shade'.%s<CR>"):format(action)
  vim.api.nvim_set_keymap(mode, key, req_module, {noremap = true, silent = true})
end

local shade = {}

-- init
shade.init = function(opts)
  state.active_overlays = {}

  opts = opts or {}
  state.debug = opts.debug or false

  state.overlay_opacity = opts.overlay_opacity or (state.debug == true and E.DEBUG_OVERLAY_OPACITY or E.DEFAULT_OVERLAY_OPACITY)
  state.opacity_step = opts.opacity_step or E.DEFAULT_OPACITY_STEP

  state.shade_nsid = api.nvim_create_namespace("shade")

  local shade_action = {
    ['brightness_up']   = 'brightness_up()',
    ['brightness_down'] = 'brightness_down()',
    ['toggle']          = 'toggle()',
  }

  if opts.keys ~= nil then
    for action, key in pairs(opts.keys) do
      if not shade_action[action] then
        log('init:keymap', 'unknown action ' .. action)
      else
        map_key('n', key, shade_action[action])
      end
    end
  end

  -- TODO: FIXME - highlights aren't available at VimEnter
  vim.defer_fn(create_overlay_highlight, 50)

  api.nvim_set_decoration_provider(state.shade_nsid, {
    on_win = shade.event_listener
  })

  -- setup autocommands
  api.nvim_command [[ augroup shade ]]
  api.nvim_command [[ au! ]]
  api.nvim_command [[ au WinEnter,VimEnter * call v:lua.require'shade'.autocmd('WinEnter', win_getid()) ]]
  api.nvim_command [[ au WinClosed         * call v:lua.require'shade'.autocmd('WinClosed', win_getid()) ]]
  api.nvim_command [[ augroup END ]]

  log("Init", "-- Shade.nvim started --")

  return true
end

--

local function create_overlay(winid)
  if not state.active_overlays[winid] then
    local wincfg = vim.api.nvim_call_function('getwininfo', {winid})[1]

    -- ignore floating windows
    if wincfg['relative'] == nil then
      wincfg = filter_wininfo(wincfg)
      local new_window = shade.create_floatwin(wincfg)
      state.active_overlays[winid] = new_window

      api.nvim_win_set_option(new_window.winid, "winhighlight", "Normal:shadeOverlay")
      api.nvim_win_set_option(new_window.winid, "winblend", state.overlay_opacity)

      log('create overlay', ("[%d] : overlay %d created"):format(winid, state.active_overlays[winid].winid))
    end
  end
end

shade.on_win_enter = function(event, winid)
  log(event, 'activating window:' .. winid)
  create_overlay(winid)
  shade.hide_overlay(winid)

  -- place overlays on all other windows
  for id, _ in pairs(state.active_overlays) do
    if id ~= winid then
      log('deactivating window', id)
      shade.show_overlay(id)
    end
  end
end

shade.event_listener = function(_, winid, _, _, _)
  -- print("yo: " .. winid)
  local cached = state.active_overlays[winid]
  if not cached then return end

  local current = filter_wininfo(vim.api.nvim_call_function('getwininfo', { winid })[1])
  -- print(vim.inspect(current))

  -- check if window dims match cache
  local resize_metrics = {'width', 'height', 'wincol', 'winrow'}
  for _, m in pairs(resize_metrics) do
    if current[m] ~= cached.wincfg[m] then
      log("event_listener: resized", winid)
      state.active_overlays[winid].wincfg = current
      api.nvim_win_set_config(cached.winid, current)
      if state.debug == true then
        show_window_metrics(state.active_overlays[winid])
      end
      goto continue
    end
  end
  ::continue::
end

--
shade.create_floatwin = function(config)
  local window = {}

  window.wincfg = config
  window.bufid  = api.nvim_create_buf(false, true)
  window.winid  = api.nvim_open_win(window.bufid, false, config)

  return window
end

--
shade.show_overlay = function(winid)
  local overlay = state.active_overlays[winid]
  if overlay then
    -- print(vim.inspect(overlay))
    api.nvim_win_set_option(overlay.winid, "winblend", state.overlay_opacity)
    log('show_overlay', ("[%d] : overlay %d ON (winblend: %d)"):format(winid, overlay.winid, state.overlay_opacity))
  else
    log('show_overlay', 'overlay not found for ' .. winid)
  end
end

-- hide the overlay on WinEnter
shade.hide_overlay = function(winid)
  local overlay = state.active_overlays[winid]
  if overlay then
    api.nvim_win_set_option(overlay.winid, "winblend", 100)
    log('hide_overlay', ("[%d] : overlay %d OFF (winblend: 100 [disabled])"):format(winid, overlay.winid))
  else
    log('hide_overlay', 'overlay not found for ' .. winid)
  end
end

-- destroy overlay window on WinClosed
 shade.on_win_closed = function(event, winid)
  local overlay = state.active_overlays[winid]
  if overlay then
    if state.debug == true then
      -- remove extmarks
      local buf = api.nvim_win_get_buf(overlay.winid)
      api.nvim_buf_clear_namespace(buf, state.shade_nsid, 1, 1)
    end
    api.nvim_win_close(overlay.winid, false)
    log(event, ("[%d] : overlay %d destroyed"):format(winid, overlay.winid))
    state.active_overlays[winid] = nil
  end
end

shade.change_brightness = function(level)
  local curr_winid = api.nvim_get_current_win()
  state.overlay_opacity = level
  for id, w in pairs(state.active_overlays) do
    if id ~= curr_winid then
      log('winblend: winid' .. w.winid, level)
      api.nvim_win_set_option(w.winid, "winblend", level)
    end
  end

  local status_opts = {
    relative  = "editor",
    style     = "minimal",
    focusable = false,
    row       = 1,
    col       = vim.o.columns - 18,
    width     = 16,
    height    = 4,
  }

  if state.notification_window == nil then
    state.notification_window = shade.create_floatwin(status_opts)
    api.nvim_win_set_option(state.notification_window.winid, "winhighlight", "Normal:ShadeBrightnessPopup")
    api.nvim_win_set_option(state.notification_window.winid, "winblend", 10)
    log('notification', 'popup created')
  end

  local output_lines = digitize(level)
  api.nvim_buf_set_lines(state.notification_window.bufid, 0,7, false, output_lines)

  if state.notification_timer ~= nil then
    state.notification_timer:stop()
    state.notification_timer = nil
    log('notification', 'timer aborted')
  end
  state.notification_timer = vim.loop.new_timer()
  state.notification_timer:start(E.NOTIFICATION_TIMEOUT, 0, vim.schedule_wrap(function()
    if api.nvim_win_is_valid(state.notification_window.winid) then
      api.nvim_win_close(state.notification_window.winid, true)
      state.notification_window = nil
      log('notification', 'timer ended')
      log('notification', 'popup closed')
    end
  end))

end

-- Main
local M = {}

M.setup = function(opts)
  if state.active == true then return end
  shade.init(opts)
  state.active = true
end

M.brightness_up = function()
  if not state.active then return end

  local adjusted = state.overlay_opacity + state.opacity_step
  if adjusted > 99 then
    adjusted = 99
  end
  shade.change_brightness(adjusted)
end

M.brightness_down = function()
  if not state.active then return end

  local adjusted = state.overlay_opacity - state.opacity_step
  if adjusted < 0 then
    adjusted = 0
  end
  shade.change_brightness(adjusted)
end

M.toggle = function()
  if state.active then
    print('off')
    -- remove overlays
    for _, overlay in pairs(state.active_overlays) do
      api.nvim_win_close(overlay.winid, true)
    end
    state.active_overlays = {}
    state.active = false
  else
    print('on')
    for _, winid in pairs(api.nvim_tabpage_list_wins(0)) do
      if winid ~= api.nvim_get_current_win() then
        create_overlay(winid)
      end
    end
    state.active = true
  end
end

M.autocmd = function(event, winid)
  if not state.active then return end
  log("AutoCmd: " .. event .. " : " .. winid)

  local event_fn = {
    ["WinEnter"] = function()
      shade.on_win_enter(event, winid)
    end,
    ["WinClosed"] = function()
      shade.on_win_closed(event, winid)
    end,
  }

  local fn = event_fn[event]
  if fn then fn() end
end

return M