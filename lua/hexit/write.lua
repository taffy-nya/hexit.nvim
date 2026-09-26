local io = require('hexit.io')

local M = {}
local attached = setmetatable({}, { __mode = 'k' })
local wait_slice = 1000
local wait_interval = 10

local function path_key(path)
  if type(path) ~= 'string' or path == '' then return nil end
  local normalized
  if path:find('://', 1, true) then
    normalized = vim.fs.normalize(path)
  else
    normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  end
  if vim.fn.has('win32') == 1 then
    normalized = normalized:gsub('\\', '/'):lower()
  end
  return normalized
end

local function notify(session, reason)
  if session.phase ~= 'closed' and type(session.on_change) == 'function' then
    pcall(session.on_change, session, reason)
  end
end

local function reject(message)
  error('hexit: ' .. message, 0)
end

local function reject_file_write()
  reject('writing to another file, a range, or append is not supported')
end

local function write_buffer(session, args)
  if vim.v.cmdbang ~= 0 then
    reject('forced writes are not supported')
  end

  local buf = session.bufnr
  if not vim.api.nvim_buf_is_valid(buf) or session.phase == 'closed' or session.token.cancelled then
    reject('save was cancelled because the buffer is closed')
  end
  local current_name = vim.api.nvim_buf_get_name(buf)
  local event_name = type(args.file) == 'string' and args.file ~= '' and args.file or current_name
  if path_key(event_name) ~= path_key(current_name) then
    reject('writing to another file is not supported')
  end
  if session.phase ~= 'ready' then
    reject('cannot save while the session is ' .. tostring(session.phase))
  end
  if session.root == nil then
    reject('cannot save without a loaded document')
  end

  local snapshot = session.root
  session.phase = 'saving'
  local render_ok, render_err = pcall(function() session.on_change(session, 'saving') end)
  if not render_ok then
    session.phase = 'ready'
    notify(session, 'ready')
    error(render_err, 0)
  end

  local done, save_err = false, nil
  local callback_called = false
  local function complete(err)
    if callback_called then return end
    callback_called = true
    save_err = err
    done = true
  end

  local started, start_err = pcall(io.save, snapshot, session.path, session.token, complete)
  if not started and not done then complete(tostring(start_err)) end
  while not done do
    -- The slice only lets vim.wait service events; there is intentionally no overall timeout.
    vim.wait(wait_slice, function() return done end, wait_interval)
  end

  if session.phase == 'closed' or session.token.cancelled or not vim.api.nvim_buf_is_valid(buf) then
    reject('save was cancelled because the buffer is closed')
  end

  if save_err ~= nil then
    session.phase = 'ready'
    notify(session, 'ready')
    error(tostring(save_err), 0)
  end

  session.saved_root = snapshot
  session.phase = 'ready'
  if session.root == snapshot then
    vim.bo[buf].modified = false
  else
    local ok, actions = pcall(require, 'hexit.actions')
    if ok and type(actions.refresh_dirty) == 'function' then
      local refreshed = pcall(actions.refresh_dirty, session)
      if not refreshed then vim.bo[buf].modified = true end
    else
      -- A newer root is conservatively dirty until actions can compare it with the saved snapshot.
      vim.bo[buf].modified = true
    end
  end
  notify(session, 'ready')
end

function M.attach(session)
  assert(type(session) == 'table', 'hexit.write.attach requires a session')
  if attached[session] then return end
  local buf = assert(session.bufnr, 'hexit.write.attach requires session.bufnr')
  local group = assert(session.augroup, 'hexit.write.attach requires session.augroup')
  assert(vim.api.nvim_buf_is_valid(buf), 'hexit.write.attach requires a valid buffer')
  attached[session] = true

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    nested = true,
    callback = function(args) write_buffer(session, args) end,
  })
  vim.api.nvim_create_autocmd({ 'FileWriteCmd', 'FileAppendCmd' }, {
    group = group,
    buffer = buf,
    callback = reject_file_write,
  })
  vim.api.nvim_create_autocmd('BufFilePre', {
    group = group,
    buffer = buf,
    callback = function() reject('renaming and :saveas are not supported') end,
  })
end

return M
