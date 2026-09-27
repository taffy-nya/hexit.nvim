local io = require('hexit.io')
local view = require('hexit.view')
local input = require('hexit.input')
local motion = require('hexit.motion')
local search = require('hexit.search')

local M = {}
local by_buffer = {}
local by_path = {}
local next_id = 0

local function path_key(path)
  local normalized = vim.fs.normalize(path)
  if vim.fn.has('win32') == 1 then
    return normalized:gsub('\\', '/'):lower()
  end
  return normalized
end

local function name_taken(path)
  local wanted = path_key(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and path_key(name) == wanted then
        return true
      end
    end
  end
  return false
end


function M.get(bufnr)
  return by_buffer[bufnr]
end

function M.find(path)
  return by_path[path_key(path)]
end

function M.close(session)
  if session.phase == 'closed' then return end
  input.invalidate_search(session)
  view.detach(session)
  motion.cancel(session)
  search.reset(session)
  input.clear_temporary(session)
  session.transaction = nil
  session.dirty_check = nil
  session.phase = 'closed'
  session.generation = session.generation + 1
  session.token.cancelled = true
  by_buffer[session.bufnr] = nil
  require('hexit.status').changed(session)
  by_path[path_key(session.path)] = nil
  if session.augroup then
    vim.api.nvim_del_augroup_by_id(session.augroup)
    session.augroup = nil
  end
  session.root, session.saved_root = nil, nil
  session.undo, session.redo = {}, {}
  session.on_change = nil
end

function M.create(path, options, on_change)
  local existing = M.find(path)
  if existing then
    if vim.api.nvim_buf_is_valid(existing.bufnr) then
      vim.api.nvim_set_current_buf(existing.bufnr)
      return existing
    end
    M.close(existing)
  end

  next_id = next_id + 1
  local buf = vim.api.nvim_create_buf(true, false)
  local name = name_taken(path) and ('hexit://%d/%s'):format(next_id, vim.fn.fnamemodify(path, ':t')) or path
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  -- FileType runs after the buffer-local input layer so explicit user mappings win.
  local session = {
    bufnr = buf, path = path, phase = 'loading', root = nil, saved_root = nil,
    revision = 0, cursor = { offset = 0, nibble = 0, area = 'hex' },
    mode = 'normal', anchor = nil, preferred_col = nil, top_row = 0,
    bytes_per_row = options.bytes_per_row, active_win = nil,
    undo = {}, redo = {}, transaction = nil, search = nil,
    generation = 0, pending = nil, eof_after_replace = false,
    token = { cancelled = false }, options = options,
    loaded_bytes = 0, total_bytes = nil,
    on_change = on_change or view.render,
  }
  by_buffer[buf] = session
  by_path[path_key(path)] = session
  session.augroup = vim.api.nvim_create_augroup('HexitSession' .. next_id, { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = session.augroup, buffer = buf,
    callback = function() M.close(session) end,
  })
  view.attach(session)
  input.attach(session)
  require('hexit.write').attach(session)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = 'hexit'
  session.token.on_progress = function(read, total)
    if session.phase ~= 'loading' then return end
    session.loaded_bytes, session.total_bytes = read, total
    session.on_change(session, 'loading')
  end
  io.load(path, session.token, function(err, root)
    if session.phase == 'closed' or session.token.cancelled then return end
    if err then
      session.phase, session.error = 'error', err
    else
      session.phase = 'ready'
      session.root, session.saved_root = root, root
    end
    session.on_change(session, session.phase)
  end)
  return session
end

return M
