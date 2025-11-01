-- lua/codex/init.lua (multi-session aware)
local vim       = vim
local installer = require 'codex.installer'
local state     = require 'codex.state'

local M         = {}

local config    = {
  keymaps      = {
    toggle         = '<leader>at',
    quit           = '<leader>aq', -- close Codex window (not the session)
    next           = '<leader>an', -- switch to next session
    prev           = '<leader>ap', -- switch to previous session
    new            = '<leader>aN', -- create a new session
    list           = '<leader>al', -- pick a session from a list
    close_session  = '<leader>ax', -- kill the current session (jobstop + wipe)
    send_selection = '<leader>as', -- send visual selection to last session in cwd
  },
  border       = 'rounded',
  width        = 0.8,
  height       = 0.8,
  cmd          = 'codex', -- can be table for argv
  model        = nil, -- e.g. 'gpt-5-codex'
  autoinstall  = true,
  winbar       = true, -- show tabs in winbar
  max_sessions = 8,
}

-- sessions: map<number, {buf, win?, job, title, cwd, model, created_at}>
state.sessions  = state.sessions or {}
state.current   = state.current or nil
state.next_id   = state.next_id or 1
state.win       = nil -- single floating window reused across sessions

local function deep_merge(dst, src)
  return vim.tbl_deep_extend('force', dst, src or {})
end

function M.setup(user_config)
  config = deep_merge(config, user_config)

  -- commands
  vim.api.nvim_create_user_command('Codex', function() M.toggle() end, { desc = 'Toggle Codex popup' })
  vim.api.nvim_create_user_command('CodexToggle', function() M.toggle() end, { desc = 'Toggle Codex popup (alias)' })
  vim.api.nvim_create_user_command('CodexNew',
    function(opts) M.new_session({ title = opts.args ~= '' and opts.args or nil }) end, {
    desc = 'Create a new Codex session',
    nargs = '?',
    complete = function() return {} end,
  })
  vim.api.nvim_create_user_command('CodexList', function() M.pick_session() end, { desc = 'List Codex sessions' })
  vim.api.nvim_create_user_command('CodexNext', function() M.next_session() end, { desc = 'Next Codex session' })
  vim.api.nvim_create_user_command('CodexPrev', function() M.prev_session() end, { desc = 'Prev Codex session' })
  vim.api.nvim_create_user_command('CodexClose', function(opts)
    local id = tonumber(opts.args)
    if id == nil then id = state.current end
    if id then M.close_session(id) end
  end, { desc = 'Close a Codex session by id (or current)', nargs = '?' })

  if config.keymaps.toggle then
    vim.keymap.set('n', config.keymaps.toggle, '<cmd>CodexToggle<CR>',
      { silent = true, noremap = true, desc = 'Codex: Toggle' })
  end

  -- Also add convenient global normal-mode mappings for other actions
  if config.keymaps.new then
    vim.keymap.set('n', config.keymaps.new, '<cmd>CodexNew<CR>',
      { silent = true, noremap = true, desc = 'Codex: New Session' })
  end
  if config.keymaps.list then
    vim.keymap.set('n', config.keymaps.list, '<cmd>CodexList<CR>',
      { silent = true, noremap = true, desc = 'Codex: List Sessions' })
  end
  if config.keymaps.next then
    vim.keymap.set('n', config.keymaps.next, '<cmd>CodexNext<CR>',
      { silent = true, noremap = true, desc = 'Codex: Next Session' })
  end
  if config.keymaps.prev then
    vim.keymap.set('n', config.keymaps.prev, '<cmd>CodexPrev<CR>',
      { silent = true, noremap = true, desc = 'Codex: Prev Session' })
  end
  if config.keymaps.close_session then
    vim.keymap.set('n', config.keymaps.close_session, '<cmd>CodexClose<CR>',
      { silent = true, noremap = true, desc = 'Codex: Close Session' })
  end
  if config.keymaps.quit then
    vim.keymap.set('n', config.keymaps.quit, function() require('codex').close() end,
      { silent = true, noremap = true, desc = 'Codex: Close Window' })
  end
  if config.keymaps.send_selection then
    vim.keymap.set('v', config.keymaps.send_selection, function() require('codex').send_selection() end,
      { silent = true, noremap = true, desc = 'Codex: Send Selection (open last)' })
  end

  -- Optional which-key group registration
  local function register_wk_group()
    local ok, wk = pcall(require, 'which-key')
    if not ok or not wk then return end
    -- which-key v3+
    if wk.add then
      pcall(wk.add, { { '<leader>a', group = 'Codex', mode = { 'n', 'v', 't' } } })
      return
    end
    -- which-key v2 fallback
    if wk.register then
      pcall(wk.register, { a = { name = 'Codex' } }, { prefix = '<leader>' })
    end
  end

  -- Try immediately (in case which-key is already loaded)
  register_wk_group()

  -- And also on common lazy-load signals
  local wk_group = vim.api.nvim_create_augroup('codex.whichkey', { clear = true })
  vim.api.nvim_create_autocmd('User', { group = wk_group, pattern = 'VeryLazy', callback = register_wk_group })
  vim.api.nvim_create_autocmd('User', { group = wk_group, pattern = 'WhichKey', callback = register_wk_group })
end

-- helpers
local function compute_dims()
  local width  = math.max(20, math.floor(vim.o.columns * config.width))
  local height = math.max(5, math.floor(vim.o.lines * config.height))
  local row    = math.floor((vim.o.lines - height) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)
  return width, height, row, col
end

local function styles_lookup()
  return {
    single = {
      { '┌', 'FloatBorder' }, { '─', 'FloatBorder' }, { '┐', 'FloatBorder' }, { '│', 'FloatBorder' },
      { '┘', 'FloatBorder' }, { '─', 'FloatBorder' }, { '└', 'FloatBorder' }, { '│', 'FloatBorder' },
    },
    double = {
      { '╔', 'FloatBorder' }, { '═', 'FloatBorder' }, { '╗', 'FloatBorder' }, { '║', 'FloatBorder' },
      { '╝', 'FloatBorder' }, { '═', 'FloatBorder' }, { '╚', 'FloatBorder' }, { '║', 'FloatBorder' },
    },
    rounded = {
      { '╭', 'FloatBorder' }, { '─', 'FloatBorder' }, { '╮', 'FloatBorder' }, { '│', 'FloatBorder' },
      { '╯', 'FloatBorder' }, { '─', 'FloatBorder' }, { '╰', 'FloatBorder' }, { '│', 'FloatBorder' },
    },
    none = nil,
  }
end

local function open_window_for(buf)
  local width, height, row, col = compute_dims()
  local border = type(config.border) == 'string' and styles_lookup()[config.border] or config.border

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_buf(state.win, buf)
    -- ensure the float is the current window so termopen attaches to this buffer
    pcall(vim.api.nvim_set_current_win, state.win)
  else
    state.win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = width,
      height = height,
      row = row,
      col = col,
      style = 'minimal',
      border = border,
    })
  end

  if config.winbar then
    local parts = {}
    for id, sess in pairs(state.sessions) do
      local mark = (id == state.current) and '●' or '○'
      local name = sess.title or ('session-' .. id)
      table.insert(parts, string.format('%s %d:%s', mark, id, name))
    end
    local text = ' Codex  ' .. table.concat(parts, '   ')
    pcall(vim.api.nvim_set_option_value, 'winbar', text, { win = state.win })
  end
end

local function create_session_buf()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'codex', { buf = buf })

  -- keymaps (terminal + normal) scoped to buffer
  local function map(mode, lhs, rhs)
    if not lhs then return end
    vim.keymap.set(mode, lhs, rhs, { noremap = true, silent = true, buffer = buf })
  end

  if config.keymaps.quit then
    map('t', config.keymaps.quit, function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 't', false)
      require('codex').close()
    end)
    map('n', config.keymaps.quit, function() require('codex').close() end)
  end

  -- Terminal convenience: exit terminal and use window commands
  map('t', '<Esc>', [[<C-\><C-n>]])
  map('t', '<C-w>', [[<C-\><C-n><C-w>]])

  map({ 'n', 't' }, config.keymaps.next, function() require('codex').next_session() end)
  map({ 'n', 't' }, config.keymaps.prev, function() require('codex').prev_session() end)
  map({ 'n', 't' }, config.keymaps.new, function() require('codex').new_session() end)
  map({ 'n', 't' }, config.keymaps.list, function() require('codex').pick_session() end)
  map({ 'n', 't' }, config.keymaps.close_session, function()
    local id = state.current
    if id then require('codex').close_session(id) end
  end)

  return buf
end

local function ensure_cmd_present(on_ready)
  local check_cmd = type(config.cmd) == 'string' and not config.cmd:find('%s') and config.cmd
      or (type(config.cmd) == 'table' and config.cmd[1]) or nil

  if check_cmd and vim.fn.executable(check_cmd) == 1 then
    on_ready(true); return
  end

  if not config.autoinstall then
    on_ready(false)
    return
  end

  installer.prompt_autoinstall(function(success)
    on_ready(success)
  end)
end

local function start_codex_job(sess)
  local argv = type(config.cmd) == 'string' and { config.cmd } or vim.deepcopy(config.cmd)
  -- pass model if set
  if config.model then
    table.insert(argv, '-m')
    table.insert(argv, config.model)
  end

  sess.job = vim.fn.termopen(argv, {
    cwd = sess.cwd or vim.loop.cwd(),
    on_exit = function()
      -- only clear the job handle; let session remain for logs until closed
      sess.job = nil
    end,
  })
end

local function auth_precheck(cb)
  -- Check if logged in (exit 0). If codex missing, we just skip.
  local ok = vim.fn.executable('codex') == 1
  if not ok then
    cb(true); return
  end
  local job = vim.fn.jobstart({ 'codex', 'login', 'status' }, {
    on_exit = function(_, code)
      if code == 0 then
        cb(true)
      else
        cb(false)
      end
    end,
  })
  if job <= 0 then cb(true) end
end

-- API

function M.new_session(opts)
  opts = opts or {}
  if vim.tbl_count(state.sessions) >= config.max_sessions then
    vim.notify('[codex.nvim] Maximum sessions reached (' .. config.max_sessions .. ')', vim.log.levels.WARN)
    return
  end

  local function actually_start()
    local id = state.next_id
    state.next_id = id + 1
    local sess = {
      id = id,
      title = opts.title or ('codex-' .. id),
      cwd = opts.cwd or vim.loop.cwd(),
      model = opts.model or config.model,
      created_at = os.time(),
    }
    sess.buf = create_session_buf()
    state.sessions[id] = sess
    state.current = id

    open_window_for(sess.buf)
    start_codex_job(sess)
  end

  ensure_cmd_present(function(available)
    if not available then
      -- show failure message in a small float with manual instructions
      local buf = create_session_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'Codex CLI not found and autoinstall disabled or failed.',
        '',
        'Install manually with one of:',
        '  npm  -g @openai/codex',
        '  brew install codex   (macOS)',
      })
      open_window_for(buf)
      return
    end

    auth_precheck(function(authed)
      if not authed then
        -- open a small login helper
        local buf = create_session_buf()
        open_window_for(buf)
        -- run login flow inside the terminal buffer
        local login_cmd = { 'codex', 'login' }
        vim.fn.termopen(login_cmd, {
          cwd = vim.loop.cwd(),
          on_exit = function()
            -- after login, start the actual session
            actually_start()
          end,
        })
      else
        actually_start()
      end
    end)
  end)
end

function M.open(id)
  id = id or state.current
  if not id or not state.sessions[id] then
    -- no sessions yet; create one
    return M.new_session()
  end
  local sess = state.sessions[id]
  open_window_for(sess.buf)
  if not sess.job then
    start_codex_job(sess)
  end
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    -- Avoid E11 when invoked while in the command-line window (q:, q/, q?)
    local in_cmdwin = false
    if vim.fn.getcmdwintype ~= nil then
      local ok, t = pcall(vim.fn.getcmdwintype)
      in_cmdwin = ok and t ~= ''
    end
    if in_cmdwin then
      vim.api.nvim_create_autocmd('CmdwinLeave', {
        once = true,
        callback = function()
          if state.win and vim.api.nvim_win_is_valid(state.win) then
            pcall(vim.api.nvim_win_close, state.win, true)
          end
          state.win = nil
        end,
      })
      return
    end
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.focus(id)
  if state.sessions[id] then
    state.current = id
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_set_buf(state.win, state.sessions[id].buf)
      open_window_for(state.sessions[id].buf)
    else
      M.open(id)
    end
  end
end

function M.list_sessions()
  local list = {}
  for id, sess in pairs(state.sessions) do
    local running = sess.job and '[running]' or '[stopped]'
    table.insert(list, { id = id, title = sess.title, running = running, cwd = sess.cwd })
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

function M.pick_session()
  local items = {}
  local idx_to_id = {}
  local i = 1
  for id, sess in pairs(state.sessions) do
    items[i] = string.format('%d  %s  %s', id, sess.title, sess.job and '●' or '○')
    idx_to_id[i] = id
    i = i + 1
  end
  if #items == 0 then return M.new_session() end
  vim.ui.select(items, { prompt = 'Select Codex session' }, function(choice, idx)
    if choice and idx then
      M.focus(idx_to_id[idx])
    end
  end)
end

function M.next_session()
  local ids = vim.tbl_keys(state.sessions)
  table.sort(ids)
  if #ids == 0 then return M.new_session() end
  local cur = state.current
  local pos = 1
  for i, id in ipairs(ids) do if id == cur then
      pos = i
      break
    end end
  local next_id = ids[(pos % #ids) + 1]
  M.focus(next_id)
end

function M.prev_session()
  local ids = vim.tbl_keys(state.sessions)
  table.sort(ids)
  if #ids == 0 then return M.new_session() end
  local cur = state.current
  local pos = 1
  for i, id in ipairs(ids) do if id == cur then
      pos = i
      break
    end end
  local prev_id = ids[((pos - 2) % #ids) + 1]
  M.focus(prev_id)
end

function M.close_session(id)
  local sess = state.sessions[id]
  if not sess then return end

  -- kill job if running
  if sess.job then pcall(vim.fn.jobstop, sess.job) end

  -- close window if showing this buffer
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local current_buf = vim.api.nvim_win_get_buf(state.win)
    if current_buf == sess.buf then
      -- switch to another session or close
      state.sessions[id] = nil
      local ids = vim.tbl_keys(state.sessions); table.sort(ids)
      state.current = ids[1]
      if state.current then
        open_window_for(state.sessions[state.current].buf)
      else
        M.close()
      end
      -- wipe buffer after switch
      pcall(vim.api.nvim_buf_delete, sess.buf, { force = true })
      return
    end
  end

  -- not visible: just delete
  pcall(vim.api.nvim_buf_delete, sess.buf, { force = true })
  state.sessions[id] = nil
  if state.current == id then
    local ids = vim.tbl_keys(state.sessions); table.sort(ids)
    state.current = ids[1]
  end
end

function M.statusline()
  local running = 0
  for _, s in pairs(state.sessions) do
    if s.job then running = running + 1 end
  end
  if running > 0 and not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return string.format('[Codex:%d]', running)
  end
  return ''
end

function M.status()
  return {
    function() return M.statusline() end,
    cond = function() return M.statusline() ~= '' end,
    icon = '',
    color = { fg = '#51afef' },
  }
end

-- Send visual selection to the latest Codex session under current cwd (or create one)
function M.send_selection()
  local function get_selection()
    local spos = vim.fn.getpos("'<")
    local epos = vim.fn.getpos("'>")
    local srow, scol = spos[2], spos[3]
    local erow, ecol = epos[2], epos[3]
    local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
    if #lines == 0 then return nil end
    lines[#lines] = string.sub(lines[#lines], 1, ecol)
    lines[1] = string.sub(lines[1], scol)
    return table.concat(lines, '\n')
  end

  local text = get_selection()
  if not text or text == '' then return end

  local root = vim.loop.cwd() or vim.fn.getcwd(-1, -1)
  root = tostring(root):gsub('/+$', '')

  local target_id, latest = nil, -1
  for id, s in pairs(state.sessions or {}) do
    if s.cwd and tostring(s.cwd):gsub('/+$','') == root then
      local t = s.created_at or 0
      if t > latest then latest = t; target_id = id end
    end
  end

  if target_id then
    M.open(target_id)
  else
    M.new_session({ cwd = root })
  end

  local function with_job(cb, tries)
    tries = tries or 40
    local function check()
      local id = target_id or state.current
      local sess = (id and state.sessions and state.sessions[id]) or nil
      if sess and sess.job then
        cb(sess)
      elseif tries > 0 then
        tries = tries - 1
        vim.defer_fn(check, 50)
      end
    end
    check()
  end

  with_job(function(sess)
    local abs = vim.api.nvim_buf_get_name(0)
    local file
    if type(abs) == 'string' and abs ~= '' then
      abs = vim.fn.fnamemodify(abs, ':p')
      local r = (vim.loop.cwd() or vim.fn.getcwd(-1, -1) or ''):gsub('/+$','')
      local rslash = r .. '/'
      if abs:sub(1, #rslash) == rslash then
        file = abs:sub(#r + 2)
      else
        file = vim.fn.fnamemodify(abs, ':t')
      end
    else
      file = '[No Name]'
    end
    local start_bp = string.char(27) .. '[200~'
    local end_bp = string.char(27) .. '[201~'
    local payload = start_bp .. string.format('[file: %s]\n', file) .. text .. end_bp
    vim.fn.chansend(sess.job, payload)
  end)
end

return setmetatable(M, {
  __call = function(_, opts)
    M.setup(opts)
    return M
  end,
})
