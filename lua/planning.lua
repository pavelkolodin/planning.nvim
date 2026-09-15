-- lua/planning.lua

local M = {}

local INDEX_FILE  = "INDEX.planning"
local TRASH_FILE  = "TRASH.planning"
local RECORDS_DIR = "records"

---------------------------------------------------------------------------
-- Plugin state
---------------------------------------------------------------------------
local state = {
  left_buf         = nil,
  right_win        = nil,
  entries          = {},
  suppress_autocmd = false, -- silence CursorMoved while mutating the menu
}

local function notify_err(msg) vim.notify(msg, vim.log.levels.ERROR) end

---------------------------------------------------------------------------
-- Seed the PRNG once so generated names differ across runs
---------------------------------------------------------------------------
local function random_initialize()
  local seed = os.time()
  local hrtime = (vim.uv and vim.uv.hrtime) or (vim.loop and vim.loop.hrtime)
  if hrtime then seed = seed + (hrtime() % 1000000) end
  seed = seed + (vim.fn.getpid() or 0) * 1000
  math.randomseed(seed)
  for _ = 1, 5 do math.random() end
end

---------------------------------------------------------------------------
-- Filesystem helpers
---------------------------------------------------------------------------
local function touch_file(path)
  local f = io.open(path, "a")
  if not f then return false end
  f:close()
  return true
end

local function ensure_layout()
  if vim.fn.filereadable(INDEX_FILE) == 0 then
    if not touch_file(INDEX_FILE) then
      notify_err("Failed to create " .. INDEX_FILE)
      return false
    end
  end

  if vim.fn.filereadable(TRASH_FILE) == 0 then
    if not touch_file(TRASH_FILE) then
      notify_err("Failed to create " .. TRASH_FILE)
      return false
    end
  end

  if vim.fn.isdirectory(RECORDS_DIR) == 0 then
    if vim.fn.mkdir(RECORDS_DIR, "p") == 0 then
      notify_err("Failed to create directory " .. RECORDS_DIR)
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------
-- INDEX.planning parsing
---------------------------------------------------------------------------
local function parse_index()
  local entries = {}
  local f = io.open(INDEX_FILE, "r")
  if not f then return entries end
  for line in f:lines() do
    if line ~= "" then
      local filename, desc = line:match("^(%S+)%s+(.*)$")
      if filename then
        entries[#entries+1] = { filename = filename, description = desc }
      end
    end
  end
  f:close()
  return entries
end

local function read_index_lines()
  local lines = {}
  local f = io.open(INDEX_FILE, "r")
  if not f then return lines end
  for line in f:lines() do lines[#lines+1] = line end
  f:close()
  return lines
end

local function write_index_lines(lines)
  local f = io.open(INDEX_FILE, "w")
  if not f then
    notify_err("Failed to write " .. INDEX_FILE)
    return false
  end
  if #lines > 0 then
    f:write(table.concat(lines, "\n") .. "\n")
  end
  f:close()
  return true
end

-- Append a single line to TRASH.planning; recreate the file if it is gone.
local function append_to_trash(line)
  if vim.fn.filereadable(TRASH_FILE) == 0 then
    if not touch_file(TRASH_FILE) then
      notify_err("Failed to recreate " .. TRASH_FILE)
      return false
    end
  end
  local f = io.open(TRASH_FILE, "a")
  if not f then
    notify_err("Failed to append to " .. TRASH_FILE)
    return false
  end
  f:write(line .. "\n")
  f:close()
  return true
end

---------------------------------------------------------------------------
-- Random file names
---------------------------------------------------------------------------
local function random_name()
  local chars = "abcdefghijklmnopqrstuvwxyz"
  local buf = {}
  for _ = 1, 8 do
    local i = math.random(1, #chars)
    buf[#buf+1] = chars:sub(i, i)
  end
  return table.concat(buf) .. ".txt"
end

local function unique_filename()
  for _ = 1, 200 do
    local name = random_name()
    if vim.fn.filereadable(RECORDS_DIR .. "/" .. name) == 0 then
      return name
    end
  end
  return tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)) .. ".txt"
end

---------------------------------------------------------------------------
-- Right pane
---------------------------------------------------------------------------
local function show_entry_in_right(idx)
  local entry = state.entries[idx]
  if not entry then return end
  if not state.right_win or not vim.api.nvim_win_is_valid(state.right_win) then
    return
  end

  local path = RECORDS_DIR .. "/" .. entry.filename
  if vim.fn.filereadable(path) == 0 then
    local f = io.open(path, "w")
    if f then f:close() end
  end

  local prev_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.right_win)

  local curbuf = vim.api.nvim_win_get_buf(state.right_win)
  if vim.bo[curbuf].buftype == "" and vim.bo[curbuf].modified then
    vim.cmd("silent! write")
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))

  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
end

-- Clear the right pane (used after deletion when the list becomes empty).
local function clear_right()
  if not state.right_win or not vim.api.nvim_win_is_valid(state.right_win) then
    return
  end
  local prev_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.right_win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype  = "nofile"
  vim.bo[buf].bufhidden= "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_win_set_buf(state.right_win, buf)

  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
end

---------------------------------------------------------------------------
-- Left pane refresh
---------------------------------------------------------------------------
local function refresh_left()
  if not state.left_buf or not vim.api.nvim_buf_is_valid(state.left_buf) then
    return
  end
  state.entries = parse_index()
  local lines = {}
  for _, e in ipairs(state.entries) do
    lines[#lines+1] = e.description
  end
  if #lines == 0 then lines = { "" } end

  vim.bo[state.left_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, lines)
  vim.bo[state.left_buf].modifiable = false
end

local function on_left_cursor_moved()
  if state.suppress_autocmd then return end
  if not state.left_buf or not vim.api.nvim_buf_is_valid(state.left_buf) then
    return
  end
  local lw = vim.fn.bufwinid(state.left_buf)
  if lw == -1 then return end
  local row = vim.api.nvim_win_get_cursor(lw)[1]
  if state.entries[row] then
    show_entry_in_right(row)
  end
end

---------------------------------------------------------------------------
-- Move current entry up/down
---------------------------------------------------------------------------
local function move_current_entry(delta)
  if not state.left_buf or not vim.api.nvim_buf_is_valid(state.left_buf) then
    notify_err("INDEX.planning pane is not open (run :IndexPlanning)")
    return
  end
  local lw = vim.fn.bufwinid(state.left_buf)
  if lw == -1 then
    notify_err("INDEX.planning pane is not open (run :IndexPlanning)")
    return
  end

  local total = #state.entries
  if total == 0 then return end

  local row    = vim.api.nvim_win_get_cursor(lw)[1]
  local target = row + delta

  -- Boundary check: topmost cannot move up, bottommost cannot move down
  if target < 1 or target > total then return end

  -- swap 2 lines in INDEX.planning
  local lines = read_index_lines()
  if #lines < target then return end
  lines[row], lines[target] = lines[target], lines[row]
  if not write_index_lines(lines) then return end

  -- refresh panel and move cursor to current place
  state.suppress_autocmd = true
  refresh_left()
  vim.api.nvim_win_set_cursor(lw, { target, 0 })
  state.suppress_autocmd = false

  -- right panel still display previous file
  show_entry_in_right(target)
end

---------------------------------------------------------------------------
-- Delete current entry
---------------------------------------------------------------------------
local function delete_current_entry()
  if not state.left_buf or not vim.api.nvim_buf_is_valid(state.left_buf) then
    notify_err("INDEX.planning pane is not open (run :IndexPlanning)")
    return
  end
  local lw = vim.fn.bufwinid(state.left_buf)
  if lw == -1 then
    notify_err("INDEX.planning pane is not open (run :IndexPlanning)")
    return
  end

  local total = #state.entries
  if total == 0 then return end

  local row = vim.api.nvim_win_get_cursor(lw)[1]
  if row < 1 or row > total then return end

  local lines = read_index_lines()
  if row > #lines then return end

  local removed = table.remove(lines, row)

  -- Push the removed line to TRASH.planning (append).
  if not append_to_trash(removed) then return end

  -- Persist the shortened INDEX.planning.
  if not write_index_lines(lines) then return end

  state.suppress_autocmd = true
  refresh_left()

  -- Keep selection stable: if we removed the last row, move up by one.
  local new_row = math.min(row, math.max(1, #state.entries))
  vim.api.nvim_win_set_cursor(lw, { new_row, 0 })
  state.suppress_autocmd = false

  if #state.entries > 0 then
    show_entry_in_right(new_row)
  else
    clear_right()
  end
end

---------------------------------------------------------------------------
-- :IndexPlanning
---------------------------------------------------------------------------
local function open_index_planning()
  if not ensure_layout() then return end

  state.entries = parse_index()
  local lines = {}
  for _, e in ipairs(state.entries) do
    lines[#lines+1] = e.description
  end
  if #lines == 0 then lines = { "" } end

  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, lines)
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].buftype    = "nofile"
  vim.bo[left_buf].bufhidden  = "wipe"
  vim.bo[left_buf].swapfile   = false
  vim.bo[left_buf].filetype   = "index_planning"
  state.left_buf = left_buf

  local orig_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local left_win = vim.api.nvim_get_current_win()
  state.right_win = orig_win

  vim.api.nvim_win_set_buf(left_win, left_buf)

  vim.wo.cursorline     = true
  vim.wo.number         = false
  vim.wo.relativenumber = false
  vim.wo.wrap           = false
  vim.wo.signcolumn     = "no"
  vim.wo.foldcolumn     = "0"
  vim.wo.winfixwidth    = true
  vim.wo.cursorlineopt  = "line"

  vim.api.nvim_set_hl(0, "PlanningCursorLine",
    { bg = "#3a3a3a", bold = true })
  vim.wo.winhighlight = "CursorLine:PlanningCursorLine"

  local cols = vim.o.columns
  vim.api.nvim_win_set_width(left_win, math.max(20, math.floor(cols * 0.25)))

  local opts = { buffer = left_buf, nowait = true, silent = true }
  local function move_cursor(d)
    local r = vim.api.nvim_win_get_cursor(0)[1]
    local t = vim.api.nvim_buf_line_count(left_buf)
    local nr = math.max(1, math.min(t, r + d))
    vim.api.nvim_win_set_cursor(0, { nr, 0 })
  end
  vim.keymap.set("n", "<Up>",   function() move_cursor(-1) end, opts)
  vim.keymap.set("n", "<Down>", function() move_cursor(1)  end, opts)
  vim.keymap.set("n", "k",      function() move_cursor(-1) end, opts)
  vim.keymap.set("n", "j",      function() move_cursor(1)  end, opts)

  -- q - move current item up, z - move current item down
  vim.keymap.set("n", "q", function() move_current_entry(-1) end, opts)
  vim.keymap.set("n", "z", function() move_current_entry(1)  end, opts)

  -- x - delete current item
  vim.keymap.set("n", "x", function() delete_current_entry() end, opts)

  -- Q - close the pane (previously q)
  vim.keymap.set("n", "Q", "<Cmd>close<CR>", opts)

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer   = left_buf,
    callback = on_left_cursor_moved,
  })

  if #state.entries > 0 then
    vim.api.nvim_win_set_cursor(left_win, { 1, 0 })
    show_entry_in_right(1)
  end
end

---------------------------------------------------------------------------
-- :PlanAdd <description>
---------------------------------------------------------------------------
local function plan_add(args)
  if not ensure_layout() then return end

  local desc = vim.trim(args or "")
  if desc == "" then
    notify_err("Usage: :PlanAdd <описание>")
    return
  end

  local filename = unique_filename()
  local path     = RECORDS_DIR .. "/" .. filename

  local nf = io.open(path, "w")
  if not nf then
    notify_err("Failed to create " .. path)
    return
  end
  nf:close()

  local lines = read_index_lines()
  table.insert(lines, 1, filename .. " " .. desc)
  if not write_index_lines(lines) then return end

  if state.left_buf and vim.api.nvim_buf_is_valid(state.left_buf) then
    local lw = vim.fn.bufwinid(state.left_buf)
    if lw ~= -1 then
      state.suppress_autocmd = true
      refresh_left()
      vim.api.nvim_win_set_cursor(lw, { 1, 0 })
      state.suppress_autocmd = false
      show_entry_in_right(1)
    end
  end

  vim.notify("ADDED: " .. desc, vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- :PlanUp / :PlanDown / :PlanDel
---------------------------------------------------------------------------
local function plan_up()   move_current_entry(-1) end
local function plan_down() move_current_entry(1)  end
local function plan_del()  delete_current_entry() end

function M.setup(opts)
  opts = opts or {}

  ---------------------------------------------------------------------------
  -- Register commands
  ---------------------------------------------------------------------------
  vim.api.nvim_create_user_command("Planning", open_index_planning, {})
  vim.api.nvim_create_user_command("PlanAdd", function(o)
    plan_add(o.args)
  end, { nargs = "*" })
  vim.api.nvim_create_user_command("PlanUp",   plan_up,   {})
  vim.api.nvim_create_user_command("PlanDown", plan_down, {})
  random_initialize()
end

return M

