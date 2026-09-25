local M = {}
local uv = vim.uv
local nonce = 0
local paths = {}
local root
local baseline = {}

local function test_dir()
  if root then return root end
  local base = vim.fn.getcwd():gsub('\\', '/') .. '/tmp'
  uv.fs_mkdir(base, 493)
  nonce = nonce + 1
  root = base .. ('/test-%d-%d-%d'):format(uv.os_getpid(), uv.hrtime(), nonce)
  assert(uv.fs_mkdir(root, 448))
  return root
end

function M.eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.bytes(...)
  return string.char(...)
end

function M.temp_file(data, name)
  nonce = nonce + 1
  local path = test_dir() .. '/' .. (name or ('fixture-' .. nonce .. '.bin'))
  local fd = assert(uv.fs_open(path, 'w', 384))
  local offset = 0
  data = data or ''
  while offset < #data do
    local written = assert(uv.fs_write(fd, data:sub(offset + 1), offset))
    assert(written > 0)
    offset = offset + written
  end
  assert(uv.fs_close(fd))
  paths[#paths + 1] = path
  return path
end

function M.read_disk(path)
  local fd = assert(uv.fs_open(path, 'r', 438))
  local stat = assert(uv.fs_fstat(fd))
  local data = {}
  local offset = 0
  while offset < stat.size do
    local part = assert(uv.fs_read(fd, math.min(65536, stat.size - offset), offset))
    assert(#part > 0)
    data[#data + 1] = part
    offset = offset + #part
  end
  assert(uv.fs_close(fd))
  return table.concat(data)
end

function M.wait_ready(buf)
  local sessions = require('hexit.session')
  local done = vim.wait(10000, function()
    local session = sessions.get(buf)
    return not session or session.phase == 'ready' or session.phase == 'error'
  end, 10)
  local session = sessions.get(buf)
  assert(done, ('load timeout: phase=%s generation=%s'):format(session and session.phase, session and session.generation))
  assert(session and session.phase == 'ready', session and session.error or 'session closed')
  return session
end

function M.begin_case()
  root, paths, baseline = nil, {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do baseline[buf] = true end
end

function M.end_case()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and (not baseline[buf] or require('hexit.session').get(buf)) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  require('hexit').setup()
  if root then
    for _, path in ipairs(paths) do
      uv.fs_unlink(path)
    end
    local scan = uv.fs_scandir(root)
    if scan then
      while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then break end
        if kind == 'file' then uv.fs_unlink(root .. '/' .. name) end
      end
    end
    uv.fs_rmdir(root)
  end
  root, paths, baseline = nil, {}, {}
end

return M
