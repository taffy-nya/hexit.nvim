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

local copy_formats = {
  'hex', 'compact', 'escaped', 'c', 'cstring', 'python', 'rust', 'ascii', 'base64',
}
local copy_registers = { '+', '*', '"' }

local ex_modifiers = {
  aboveleft = 3,
  belowright = 3,
  botright = 2,
  browse = 3,
  confirm = 4,
  filter = 6,
  hide = 3,
  horizontal = 3,
  keepalt = 5,
  keepjumps = 5,
  keepmarks = 5,
  keeppatterns = 5,
  leftabove = 5,
  lockmarks = 5,
  noautocmd = 3,
  noswapfile = 3,
  rightbelow = 5,
  sandbox = 3,
  silent = 3,
  tab = 3,
  topleft = 2,
  unsilent = 3,
  verbose = 4,
  vertical = 4,
}

local function skip_space(text, pos)
  while text:sub(pos, pos):match('%s') do pos = pos + 1 end
  return pos
end

local function skip_search_address(text, pos, delimiter)
  local cursor = pos + 1
  while cursor <= #text do
    local char = text:sub(cursor, cursor)
    if char == '\\' then
      cursor = cursor + 2
    elseif char == delimiter then
      return cursor + 1
    else
      cursor = cursor + 1
    end
  end
end

local function skip_address(text, pos)
  local char = text:sub(pos, pos)
  local cursor
  if char:match('%d') then
    cursor = pos + 1
    while text:sub(cursor, cursor):match('%d') do cursor = cursor + 1 end
  elseif char == '.' or char == '$' or char == '%' then
    cursor = pos + 1
  elseif char == "'" and pos < #text then
    cursor = pos + 2
  elseif char == '/' or char == '?' then
    cursor = skip_search_address(text, pos, char)
    if not cursor then return nil end
  elseif char == '\\' and (text:sub(pos + 1, pos + 1) == '/'
      or text:sub(pos + 1, pos + 1) == '?'
      or text:sub(pos + 1, pos + 1) == '&') then
    cursor = pos + 2
  elseif char == '+' or char == '-' then
    cursor = pos + 1
    while text:sub(cursor, cursor):match('%d') do cursor = cursor + 1 end
  else
    return nil
  end

  while true do
    local offset = skip_space(text, cursor)
    local sign = text:sub(offset, offset)
    if sign ~= '+' and sign ~= '-' then break end
    cursor = offset + 1
    while text:sub(cursor, cursor):match('%d') do cursor = cursor + 1 end
  end
  return cursor
end

local function skip_range(text, pos)
  local cursor = skip_address(text, pos)
  if not cursor then return nil end

  while true do
    local separator = skip_space(text, cursor)
    local char = text:sub(separator, separator)
    if char ~= ',' and char ~= ';' then return cursor end
    local next_address = skip_address(text, skip_space(text, separator + 1))
    cursor = next_address or separator + 1
  end
end

local function modifier_name(word)
  if word:match('^verbose=%d+$') then return 'verbose' end
  local bang = word:sub(-1) == '!'
  if bang then word = word:sub(1, -2) end

  for name, minimum in pairs(ex_modifiers) do
    if #word >= minimum and #word <= #name and name:sub(1, #word) == word then
      if not bang or name == 'silent' or name == 'filter' then return name end
      return nil
    end
  end
end
local function copy_as_arguments_start(prefix)
  local cursor = skip_space(prefix, 1)
  if prefix:sub(cursor, cursor) == ':' then cursor = cursor + 1 end
  cursor = skip_space(prefix, cursor)

  while cursor <= #prefix do
    local range_end = skip_range(prefix, cursor)
    if range_end then
      cursor = skip_space(prefix, range_end)
    else
      local token_end = cursor
      while token_end <= #prefix and not prefix:sub(token_end, token_end):match('%s') do
        token_end = token_end + 1
      end
      local word = prefix:sub(cursor, token_end - 1)
      if word == 'HexCopyAs' then return token_end end

      local modifier = modifier_name(word)
      if not modifier then return nil end
      cursor = skip_space(prefix, token_end)
      if modifier == 'filter' then
        local char = prefix:sub(cursor, cursor)
        if char == '/' or char == '?' then
          cursor = skip_search_address(prefix, cursor, char)
          if not cursor then return nil end
          cursor = skip_space(prefix, cursor)
        end
      end
    end
  end
end

local function copy_as_slot(arguments)
  local cursor, complete = 1, 0
  while cursor <= #arguments do
    cursor = skip_space(arguments, cursor)
    if cursor > #arguments then break end
    while cursor <= #arguments and not arguments:sub(cursor, cursor):match('%s') do
      cursor = cursor + 1
    end
    if cursor > #arguments then break end
    complete = complete + 1
  end
  return complete
end

function M.complete_copy_as(arglead, cmdline, cursorpos)
  if type(cmdline) ~= 'string' or type(cursorpos) ~= 'number' then return {} end
  local prefix = cmdline:sub(1, math.max(0, math.min(#cmdline, cursorpos)))
  local arguments_start = copy_as_arguments_start(prefix)
  if not arguments_start then return {} end

  local arguments = prefix:sub(arguments_start)
  local slot = copy_as_slot(arguments)
  local candidates = slot == 0 and copy_formats or slot == 1 and copy_registers or {}
  local lead = arglead or ''
  local matches = {}
  for _, candidate in ipairs(candidates) do
    if candidate:sub(1, #lead) == lead then matches[#matches + 1] = candidate end
  end
  return matches
end

function M.search(text)
  local session = current()
  require('hexit.input').invalidate_search(session)
  local kind, pattern = text:match('^(%S+)%s(.*)$')
  if kind ~= 'hex' and kind ~= 'ascii' then
    error('hexit: expected HexSearch {hex|ascii} {pattern}', 2)
  end
  if pattern == '' then error('hexit: search pattern must not be empty', 2) end
  local query, err = search.parse(kind, pattern, session.options)
  if not query then error('hexit: ' .. err, 2) end
  search.start(session, query, 1, 1)
end

return M
