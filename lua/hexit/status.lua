local M = {}
local previous = {}
local queued = {}

local mode_names = {
  normal = 'NORMAL', visual = 'VISUAL', visual_line = 'VISUAL LINE', replace = 'REPLACE',
}

local function address(offset, width, uppercase)
  return '0x' .. (uppercase and '%0' .. width .. 'X' or '%0' .. width .. 'x'):format(offset)
end

function M.get(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if type(bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local session = require('hexit.session').get(bufnr)
  if not session or session.phase == 'closed' then return nil end
  return M.project(session)
end

function M.project(session)
  local bufnr = session.bufnr
  local root = session.root
  local size = root and root.size or nil
  local width = math.max(8, #(('%X'):format(math.max((size or 0) - 1, 0))))
  local uppercase = session.options.uppercase_hex
  local offset = size and size > 0 and session.cursor.offset or nil
  local selection
  if session.anchor ~= nil and size and size > 0 then
    local first, stop = require('hexit.actions').selection(session)
    if first then selection = { start = first, stop = stop, length = stop - first } end
  end
  local state = session.search
  local search
  if state and state.query then
    search = {
      kind = state.query.kind, direction = state.direction, visible = state.visible == true,
      pending = state.visible == true and state.pending == true,
      ordinal = state.visible == true and state.ordinal or nil, total = state.total,
    }
  end
  local area = session.cursor.area
  local result = {
    bufnr = bufnr, phase = session.phase, mode = session.mode,
    mode_text = mode_names[session.mode], area = area,
    nibble = area == 'hex' and (session.cursor.nibble == 0 and 'high' or 'low') or nil,
    size = size, offset = offset,
    bytes_per_row = session.layout and session.layout.bpr or nil,
    selection = selection, search = search,
    input_kind = session.input and session.input.search_kind or nil,
    position_text = size == nil and '--' or size == 0 and '(empty)' or address(offset, width, uppercase),
    selection_text = selection and ('Sel: %d B'):format(selection.length) or '',
    range_text = selection and ('%s–%s (%d B)'):format(
      address(selection.start, width, uppercase), address(selection.stop - 1, width, uppercase), selection.length) or '',
    area_text = area == 'ascii' and 'ASCII' or session.cursor.nibble == 0 and 'HEX HI' or 'HEX LO',
    search_text = '',
  }
  if search and search.visible then
    if search.pending then
      result.search_text = 'searching… ?/?'
    elseif search.total == 0 then
      result.search_text = '0/0'
    elseif search.total then
      result.search_text = (search.ordinal or '?') .. '/' .. search.total
    end
  end
  return result
end

function M.header(snapshot)
  if type(snapshot) ~= 'table' or not mode_names[snapshot.mode]
    or (snapshot.area ~= 'hex' and snapshot.area ~= 'ascii')
    or type(snapshot.position_text) ~= 'string' then
    return { mode = '', right = '' }
  end
  local mode = snapshot.mode == 'visual_line' and 'V-LINE' or mode_names[snapshot.mode]
  local parts = {}
  if snapshot.selection then parts[#parts + 1] = snapshot.selection.length .. 'B' end
  local search = snapshot.search
  if search and search.visible then
    if search.pending then
      parts[#parts + 1] = '?/?'
    elseif search.total == 0 then
      parts[#parts + 1] = '0/0'
    elseif search.total then
      parts[#parts + 1] = (search.ordinal or '?') .. '/' .. search.total
    end
  end
  parts[#parts + 1] = snapshot.area == 'ascii' and 'ASCII' or 'HEX'
  parts[#parts + 1] = snapshot.position_text
  return { mode = mode, right = table.concat(parts, '  ') }
end

function M.changed(session)
  local buf = session.bufnr
  local current = M.get(buf)
  if current and current.search and not current.search.visible then
    current.search.total = nil
  end
  if vim.deep_equal(previous[buf], current) then return end
  previous[buf] = current
  if queued[buf] then return end
  queued[buf] = true
  vim.schedule(function()
    queued[buf] = nil
    vim.api.nvim_exec_autocmds('User', { pattern = 'HexitStatusChanged', data = { bufnr = buf } })
    if not require('hexit.session').get(buf) then previous[buf] = nil end
  end)
end

return M
