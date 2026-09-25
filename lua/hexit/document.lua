local M = {}

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_ITER_CHUNK = 64 * 1024
local min = math.min
local floor = math.floor
local concat = table.concat
local sub = string.sub
local byte = string.byte

local function is_safe_integer(value)
  return type(value) == 'number'
    and value == value
    and value >= 0
    and value <= MAX_SAFE_INTEGER
    and floor(value) == value
end

local function require_integer(value, name)
  if not is_safe_integer(value) then
    error(('document: %s must be a non-negative safe integer'):format(name), 3)
  end
end

local function require_root(root, name)
  if type(root) ~= 'table'
    or type(root.pieces) ~= 'table'
    or type(root.ends) ~= 'table'
    or not is_safe_integer(root.size)
    or #root.pieces ~= #root.ends
  then
    error(('document: %s must be a Root'):format(name), 3)
  end
end

local function require_range(root, start, len, name)
  require_integer(start, name .. ' start')
  require_integer(len, name .. ' length')
  if start > root.size or len > root.size - start then
    error(('document: %s range is out of bounds'):format(name), 3)
  end
end

local function empty_root()
  return { pieces = {}, ends = {}, size = 0 }
end

local function new_builder()
  return { pieces = {}, ends = {}, size = 0 }
end

local function append_piece(builder, data, start, len)
  if len == 0 then return end
  if len > MAX_SAFE_INTEGER - builder.size then
    error('document: resulting size exceeds maximum safe integer', 3)
  end

  local pieces = builder.pieces
  local previous = pieces[#pieces]
  local merges = previous
    and previous.data == data
    and previous.start + previous.len == start
  if merges then
    previous.len = previous.len + len
  else
    pieces[#pieces + 1] = { data = data, start = start, len = len }
  end
  builder.size = builder.size + len
  local ends = builder.ends
  if merges then
    ends[#ends] = builder.size
  else
    ends[#ends + 1] = builder.size
  end
end

local function finish(builder)
  return { pieces = builder.pieces, ends = builder.ends, size = builder.size }
end

-- Return the piece whose cumulative end is the first one greater than offset.
local function find_piece(root, offset)
  local low, high = 1, #root.ends
  while low <= high do
    local middle = floor((low + high) / 2)
    if root.ends[middle] <= offset then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return low
end

local function append_range(builder, root, start, len)
  if len == 0 then return end
  local index = find_piece(root, start)
  local before = index > 1 and root.ends[index - 1] or 0
  local within = start - before
  local remaining = len

  while remaining > 0 do
    local piece = root.pieces[index]
    local take = min(remaining, piece.len - within)
    append_piece(builder, piece.data, piece.start + within, take)
    remaining = remaining - take
    index = index + 1
    within = 0
  end
end

local function new_cursor(root, offset)
  local index = find_piece(root, offset)
  local before = index > 1 and root.ends[index - 1] or 0
  return { index = index, within = offset - before }
end

local function advance_cursor(root, cursor, amount)
  cursor.within = cursor.within + amount
  local piece = root.pieces[cursor.index]
  if cursor.within == piece.len then
    cursor.index = cursor.index + 1
    cursor.within = 0
  end
end

function M.empty()
  return empty_root()
end

function M.from_chunks(chunks)
  if type(chunks) ~= 'table' then
    error('document.from_chunks: chunks must be an array of strings', 2)
  end

  local builder = new_builder()
  for _, data in ipairs(chunks) do
    if type(data) ~= 'string' then
      error('document.from_chunks: every chunk must be a string', 2)
    end
    local len = #data
    if len > MAX_SAFE_INTEGER - builder.size then
      error('document.from_chunks: resulting size exceeds maximum safe integer', 2)
    end
    append_piece(builder, data, 0, len)
  end
  return finish(builder)
end

function M.read(root, start, len)
  require_root(root, 'root')
  require_range(root, start, len, 'read')
  if len == 0 then return '' end

  local index = find_piece(root, start)
  local before = index > 1 and root.ends[index - 1] or 0
  local within = start - before
  local remaining = len
  local fragments = {}
  local fragment_count = 0

  while remaining > 0 do
    local piece = root.pieces[index]
    local take = min(remaining, piece.len - within)
    local data_start = piece.start + within
    local fragment
    if data_start == 0 and take == #piece.data then
      fragment = piece.data
    else
      fragment = sub(piece.data, data_start + 1, data_start + take)
    end
    fragment_count = fragment_count + 1
    fragments[fragment_count] = fragment
    remaining = remaining - take
    index = index + 1
    within = 0
  end

  if fragment_count == 1 then return fragments[1] end
  return concat(fragments)
end

function M.slice(root, start, len)
  require_root(root, 'root')
  require_range(root, start, len, 'slice')
  if len == 0 then return empty_root() end
  if start == 0 and len == root.size then return root end

  local builder = new_builder()
  append_range(builder, root, start, len)
  return finish(builder)
end

function M.splice(root, start, remove_len, insert_root)
  require_root(root, 'root')
  require_root(insert_root, 'insert_root')
  require_range(root, start, remove_len, 'splice')

  local kept_size = root.size - remove_len
  if insert_root.size > MAX_SAFE_INTEGER - kept_size then
    error('document.splice: resulting size exceeds maximum safe integer', 2)
  end
  if remove_len == 0 and insert_root.size == 0 then return root end

  local builder = new_builder()
  append_range(builder, root, 0, start)
  append_range(builder, insert_root, 0, insert_root.size)
  local suffix_start = start + remove_len
  append_range(builder, root, suffix_start, root.size - suffix_start)
  return finish(builder)
end

function M.iter(root, start, len, max_chunk)
  require_root(root, 'root')
  require_range(root, start, len, 'iter')
  if max_chunk == nil then
    max_chunk = MAX_ITER_CHUNK
  else
    require_integer(max_chunk, 'iter max_chunk')
    if max_chunk == 0 then
      error('document.iter: max_chunk must be positive', 2)
    end
  end
  local chunk_limit = min(max_chunk, MAX_ITER_CHUNK)
  local remaining = len
  local cursor
  if remaining > 0 then cursor = new_cursor(root, start) end

  return function()
    if remaining == 0 then return nil end
    local piece = root.pieces[cursor.index]
    local take = min(remaining, piece.len - cursor.within, chunk_limit)
    local data_start = piece.start + cursor.within
    local chunk
    if data_start == 0 and take == #piece.data then
      chunk = piece.data
    else
      chunk = sub(piece.data, data_start + 1, data_start + take)
    end
    remaining = remaining - take
    advance_cursor(root, cursor, take)
    return chunk
  end
end

function M.equal(a, b)
  require_root(a, 'left root')
  require_root(b, 'right root')
  if a.size ~= b.size then return false end
  if a == b then return true end
  if a.size == 0 then return true end

  local left = new_cursor(a, 0)
  local right = new_cursor(b, 0)
  local offset = 0
  while offset < a.size do
    local ap = a.pieces[left.index]
    local bp = b.pieces[right.index]
    local take = min(ap.len - left.within, bp.len - right.within)
    local astart = ap.start + left.within
    local bstart = bp.start + right.within

    if ap.data ~= bp.data or astart ~= bstart then
      local compared = 0
      while compared < take do
        local count = min(take - compared, MAX_ITER_CHUNK)
        if sub(ap.data, astart + compared + 1, astart + compared + count)
          ~= sub(bp.data, bstart + compared + 1, bstart + compared + count)
        then
          return false
        end
        compared = compared + count
      end
    end

    offset = offset + take
    advance_cursor(a, left, take)
    advance_cursor(b, right, take)
  end
  return true
end

function M.dirty_runs(root, saved, start, len)
  require_root(root, 'root')
  require_root(saved, 'saved root')
  require_range(root, start, len, 'dirty_runs')
  local runs = {}
  if len == 0 then return runs end

  local stop = start + len
  local position = start
  local current = new_cursor(root, start)
  local baseline
  if position < saved.size then baseline = new_cursor(saved, position) end
  local dirty_start

  local function close_run(at)
    if dirty_start ~= nil then
      runs[#runs + 1] = { dirty_start, at }
      dirty_start = nil
    end
  end

  while position < stop do
    if position >= saved.size then
      if dirty_start == nil then dirty_start = position end
      close_run(stop)
      break
    end

    local cp = root.pieces[current.index]
    local sp = saved.pieces[baseline.index]
    local current_start = cp.start + current.within
    local saved_start = sp.start + baseline.within
    local count = min(
      stop - position,
      cp.len - current.within,
      sp.len - baseline.within,
      saved.size - position,
      MAX_ITER_CHUNK
    )

    if cp.data == sp.data and current_start == saved_start then
      close_run(position)
    else
      local same = sub(cp.data, current_start + 1, current_start + count)
        == sub(sp.data, saved_start + 1, saved_start + count)
      if same then
        close_run(position)
      else
        for i = 0, count - 1 do
          local differs = byte(cp.data, current_start + i + 1)
            ~= byte(sp.data, saved_start + i + 1)
          if differs then
            if dirty_start == nil then dirty_start = position + i end
          else
            close_run(position + i)
          end
        end
      end
    end

    position = position + count
    advance_cursor(root, current, count)
    advance_cursor(saved, baseline, count)
  end

  close_run(stop)
  return runs
end

return M
