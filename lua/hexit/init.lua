local config = require('hexit.config')
local sessions = require('hexit.session')

local M = {}
local current = config.merge()

local function require_version()
  if vim.fn.has('nvim-0.12') ~= 1 then
    error('hexit: Neovim 0.12 or newer is required', 2)
  end
end

function M.setup(opts)
  require_version()
  current = config.merge(opts)
end

function M.get_status(bufnr)
  return require('hexit.status').get(bufnr)
end

function M.open(path)
  require_version()
  if path == nil or path == '' then
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= '' or vim.api.nvim_buf_get_name(buf) == '' then
      error('hexit: current buffer must be a named ordinary file', 2)
    end
    if vim.bo[buf].modified then
      error('hexit: save the modified source buffer before opening Hex', 2)
    end
    path = vim.api.nvim_buf_get_name(buf)
  elseif type(path) ~= 'string' then
    error('hexit: path must be a string', 2)
  end
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if absolute == '' then error('hexit: empty file path', 2) end
  return sessions.create(absolute, vim.deepcopy(current))
end

return M
