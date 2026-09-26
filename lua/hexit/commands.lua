local sessions = require('hexit.session')
local view = require('hexit.view')
local motion = require('hexit.motion')
local search = require('hexit.search')

local M = {}

local function current(allow_saving)
  local session = sessions.get(vim.api.nvim_get_current_buf())
  if not session then error('hexit: command requires a Hexit buffer', 2) end
  if session.phase ~= 'ready' and (not allow_saving or session.phase ~= 'saving') then
    error('hexit: binary snapshot is not ready', 2)
  end
  return session
end

function M.goto_offset(text)
  local session = current(true)
  local hex = text:match('^0x([%da-fA-F]+)$')
  local decimal = text:match('^(%d+)$')
  if not hex and not decimal then error('hexit: offset must be decimal or 0x-prefixed hex', 2) end
  local digits, base = hex or decimal, hex and 16 or 10
  if session.root.size == 0 then error('hexit: empty file has no Byte to navigate to', 2) end
  local value = 0
  for i = 1, #digits do
    local digit = tonumber(digits:sub(i, i), base)
    if value > math.floor((session.root.size - 1 - digit) / base) then
      error('hexit: offset is outside the file', 2)
    end
    value = value * base + digit
  end
  motion.cancel(session)
  session.cursor.offset, session.cursor.nibble = value, 0
  session.preferred_col = nil
  view.render(session)
end

function M.bytes_per_row(text)
  local session = current(true)
  local width = ({ ['8'] = 8, ['16'] = 16, ['32'] = 32, auto = 'auto' })[text]
  if not width then
    error('hexit: bytes per row must be 8, 16, 32 or auto', 2)
  end
  motion.cancel(session)
  session.options.bytes_per_row = width
  session.preferred_col = nil
  view.render(session)
end

function M.copy_as(text)
  local session = current()
  local words = {}
  for word in text:gmatch('%S+') do words[#words + 1] = word end
  if #words > 2 then error('hexit: expected [format] [register]', 2) end
  require('hexit.actions').copy_as(session, words[1] or session.options.default_copy_format, words[2] or '+')
end

function M.search(text)
  local session = current()
  if session.input then
    session.input.search_prompt = (session.input.search_prompt or 0) + 1
  end
  local kind, pattern = text:match('^(%S+)%s(.*)$')
  if kind ~= 'hex' and kind ~= 'ascii' then
    error('hexit: expected HexSearch {hex|ascii} {pattern}', 2)
  end
  if pattern == '' and session.search and session.search.query then
    search.start(session, session.search.query, 1, 1)
    return
  end
  local query, err = search.parse(kind, pattern, session.options)
  if not query then error('hexit: ' .. err, 2) end
  search.start(session, query, 1, 1)
end

return M
