local M = {}

-- Cooperative long-word scanning resumes through a zero-delay timer so the
-- event loop (timers, polling) is never starved by a self-rescheduling chain.
local function yield(callback)
  vim.defer_fn(callback, 0)
end

local pending = setmetatable({}, { __mode = 'k' })
local MAX_SCAN_BYTES = 64 * 1024
local SCAN_BUDGET_NS = 8 * 1000 * 1000
local TIME_CHECK_INTERVAL = 256
local floor = math.floor
local min = math.min
local byte = string.byte

local function checked_count(count, has_count)
  if not has_count then return 1 end
  if type(count) ~= 'number' or count < 1 or floor(count) ~= count then
    error('motion: count must be a positive integer', 3)
  end
  return count
end

local function checked_height(height)
  if type(height) ~= 'number' or height < 1 or floor(height) ~= height then
    return 1
  end
  return height
end

local function rows_in(root, bpr)
  return root.size == 0 and 0 or floor((root.size - 1) / bpr) + 1
end

local function clamp_top(top_row, total_rows, height)
  local maximum = math.max(0, total_rows - height)
  return math.max(0, math.min(top_row or 0, maximum))
end

function M.visible_top(top_row, row, total_rows, height, scrolloff)
  local margin = math.min(math.max(0, scrolloff or 0), floor((height - 1) / 2))
  top_row = clamp_top(top_row, total_rows, height)
  if row < top_row + margin then
    top_row = row - margin
  elseif row > top_row + height - 1 - margin then
    top_row = row - (height - 1 - margin)
  end
  return clamp_top(top_row, total_rows, height)
end

local function limit_shift(value, amount, direction, maximum)
  if direction < 0 then
    if amount >= value then return 0 end
    return value - amount
  end
  local available = maximum - value
  if amount >= available then return maximum end
  return value + amount
end

local function bounded_rows(step, count, available)
  if available <= 0 then return 0 end
  if count >= math.ceil(available / step) then return available end
  return step * count
end

local function row_offset(row, column, root, bpr)
  local start = row * bpr
  local last_column = min(bpr - 1, root.size - 1 - start)
  return start + min(column, last_column)
end

local function copy_cursor(cursor)
  return {
    offset = cursor.offset,
    nibble = cursor.nibble or 0,
    area = cursor.area or 'hex',
  }
end

local function move_horizontal(cursor, root, count, direction)
  local last = root.size - 1
  if cursor.area ~= 'hex' then
    cursor.offset = limit_shift(cursor.offset, count, direction, last)
    cursor.nibble = 0
    return
  end

  local nibble = cursor.nibble == 1 and 1 or 0
  if direction < 0 then
    if count <= nibble then
      cursor.nibble = nibble - count
      return
    end
    local remaining = count - nibble
    local bytes_left = floor((remaining + 1) / 2)
    if bytes_left > cursor.offset then
      cursor.offset, cursor.nibble = 0, 0
      return
    end
    cursor.offset = cursor.offset - bytes_left
    cursor.nibble = remaining % 2
    return
  end

  local remaining
  if nibble == 0 then
    if count == 1 then
      cursor.nibble = 1
      return
    end
    remaining = count - 1
  else
    remaining = count
  end
  local bytes_right = floor((remaining + 1) / 2)
  if bytes_right > last - cursor.offset then
    cursor.offset, cursor.nibble = last, 1
    return
  end
  cursor.offset = cursor.offset + bytes_right
  cursor.nibble = remaining % 2 == 1 and 0 or 1
end

local function hex_word_motion(cursor, root, count, action)
  local last = root.size - 1
  if action == 'WordNext' then
    cursor.offset = limit_shift(cursor.offset, count, 1, last)
    cursor.nibble = 0
  elseif action == 'WordPrev' then
    cursor.offset = limit_shift(cursor.offset, count, -1, last)
    cursor.nibble = 0
  else
    local advance = count - 1 + (cursor.nibble == 1 and 1 or 0)
    cursor.offset = limit_shift(cursor.offset, advance, 1, last)
    cursor.nibble = 1
  end
end

local function new_reader(root, start)
  local low, high = 1, #root.ends
  while low < high do
    local middle = floor((low + high) / 2)
    if root.ends[middle] > start then high = middle else low = middle + 1 end
  end
  local before = low > 1 and root.ends[low - 1] or 0
  return { root = root, offset = start, index = low, within = start - before }
end

local function reader_byte(reader, offset)
  if offset == reader.offset + 1 then
    local piece = reader.root.pieces[reader.index]
    if reader.within + 1 == piece.len then
      reader.index, reader.within = reader.index + 1, 0
    else
      reader.within = reader.within + 1
    end
    reader.offset = offset
  elseif offset == reader.offset - 1 then
    if reader.within == 0 then
      reader.index = reader.index - 1
      reader.within = reader.root.pieces[reader.index].len - 1
    else
      reader.within = reader.within - 1
    end
    reader.offset = offset
  elseif offset ~= reader.offset then
    local low, high = 1, #reader.root.ends
    while low < high do
      local middle = floor((low + high) / 2)
      if reader.root.ends[middle] > offset then high = middle else low = middle + 1 end
    end
    local before = low > 1 and reader.root.ends[low - 1] or 0
    reader.index, reader.within, reader.offset = low, offset - before, offset
  end
  local piece = reader.root.pieces[reader.index]
  return byte(piece.data, piece.start + reader.within + 1)
end

local function byte_class(value)
  if (value >= 65 and value <= 90)
    or (value >= 97 and value <= 122)
    or (value >= 48 and value <= 57)
    or value == 95 then
    return 1
  end
  if (value >= 9 and value <= 13) or value == 32 then return 0 end
  return 2
end

local function ascii_word_motion(cursor, root, count, action)
  local size = root.size
  local offset = cursor.offset
  local reader = new_reader(root, offset)
  local reads = 0
  local slice_start = vim.uv.hrtime()

  local function class_at(at)
    local result = byte_class(reader_byte(reader, at))
    reads = reads + 1
    if reads % TIME_CHECK_INTERVAL == 0 or reads >= MAX_SCAN_BYTES then
      if reads >= MAX_SCAN_BYTES or vim.uv.hrtime() - slice_start >= SCAN_BUDGET_NS then
        coroutine.yield()
        reads = 0
        slice_start = vim.uv.hrtime()
      end
    end
    return result
  end

  for _ = 1, count do
    local previous = offset
    if action == 'WordNext' then
      if offset >= size - 1 then break end
      local class = class_at(offset)
      if class ~= 0 then
        repeat
          offset = offset + 1
          if offset >= size or class_at(offset) ~= class then break end
        until false
      end
      while offset < size and class_at(offset) == 0 do
        offset = offset + 1
      end
      if offset >= size then offset = size - 1 end
    elseif action == 'WordPrev' then
      if offset > 0 then
        offset = offset - 1
        while offset > 0 and class_at(offset) == 0 do
          offset = offset - 1
        end
        local class = class_at(offset)
        if class ~= 0 then
          while offset > 0 and class_at(offset - 1) == class do
            offset = offset - 1
          end
        end
      end
    else -- WordEnd
      if offset < size - 1 then
        local class = class_at(offset)
        if class == 0 or class_at(offset + 1) ~= class then
          offset = offset + 1
        end
        while offset < size and class_at(offset) == 0 do
          offset = offset + 1
        end
        if offset >= size then
          offset = size - 1
        else
          class = class_at(offset)
          while offset < size - 1 and class_at(offset + 1) == class do
            offset = offset + 1
          end
        end
      end
    end
    if offset == previous then break end
  end
  cursor.offset = offset
  return cursor
end

local function commit(session, cursor, preferred_col, top_row, root, bpr, height, captured)
  if session.phase == 'closed'
    or session.root ~= root
    or session.generation ~= captured.generation
    or session.bytes_per_row ~= bpr
    or session.cursor.offset ~= captured.cursor.offset
    or session.cursor.nibble ~= captured.cursor.nibble
    or session.cursor.area ~= captured.cursor.area then
    return false
  end

  session.cursor.offset = cursor.offset
  session.cursor.nibble = cursor.nibble
  session.cursor.area = cursor.area
  session.preferred_col = preferred_col
  local total_rows = rows_in(root, bpr)
  session.top_row = M.visible_top(top_row, floor(cursor.offset / bpr), total_rows, height,
    session.scrolloff or 0)
  return true
end

local function finish_pending(session, token)
  if pending[session] ~= token then return end
  if session.phase == 'closed'
    or session.root ~= token.root
    or session.generation ~= token.generation
    or session.bytes_per_row ~= token.bpr
    or session.cursor.offset ~= token.captured.cursor.offset
    or session.cursor.nibble ~= token.captured.cursor.nibble
    or session.cursor.area ~= token.captured.cursor.area then
    pending[session] = nil
    return
  end

  local ok, cursor = coroutine.resume(token.co)
  if not ok then
    pending[session] = nil
    error(cursor, 0)
  end
  if coroutine.status(token.co) ~= 'dead' then
    yield(function() finish_pending(session, token) end)
    return
  end

  pending[session] = nil
  if commit(session, cursor, nil, token.top_row, token.root, token.bpr, token.height, token.captured) then
    token.done()
  end
end

function M.cancel(session)
  local token = pending[session]
  if token then
    token.cancelled = true
    pending[session] = nil
  end
end

function M.move(session, action, count, has_count, height, done)
  M.cancel(session)
  local repetitions = checked_count(count, has_count)
  local root = session.root
  local bpr = session.bytes_per_row
  local callback = done or function() end
  if not root or root.size == 0 then
    callback()
    return
  end
  if type(bpr) ~= 'number' or bpr < 1 or floor(bpr) ~= bpr then
    error('motion: bytes_per_row must be a positive integer', 2)
  end

  local rows = rows_in(root, bpr)
  local view_height = checked_height(height)
  local original = copy_cursor(session.cursor)
  original.offset = math.max(0, math.min(original.offset, root.size - 1))
  local cursor = copy_cursor(original)
  local preferred_col = session.preferred_col
  local top_row = session.top_row or 0
  local row = floor(cursor.offset / bpr)

  if action == 'Left' then
    move_horizontal(cursor, root, repetitions, -1)
    preferred_col = nil
  elseif action == 'Right' then
    move_horizontal(cursor, root, repetitions, 1)
    preferred_col = nil
  elseif action == 'Up' or action == 'Down' then
    local column = preferred_col
    if type(column) ~= 'number' or column < 0 or floor(column) ~= column then
      column = cursor.offset % bpr
    end
    preferred_col = min(column, bpr - 1)
    local available = action == 'Up' and row or rows - 1 - row
    local amount = min(repetitions, available)
    local target_row = action == 'Up' and row - amount or row + amount
    cursor.offset = row_offset(target_row, preferred_col, root, bpr)
  elseif action == 'HalfUp' or action == 'HalfDown' or action == 'PageUp' or action == 'PageDown' then
    local column = preferred_col
    if type(column) ~= 'number' or column < 0 or floor(column) ~= column then
      column = cursor.offset % bpr
    end
    preferred_col = min(column, bpr - 1)
    local direction = (action == 'HalfUp' or action == 'PageUp') and -1 or 1
    local step
    if action == 'HalfUp' or action == 'HalfDown' then
      step = math.max(1, floor(view_height / 2))
    else
      step = math.max(1, view_height - 2)
    end
    local available = direction < 0 and row or rows - 1 - row
    local amount = bounded_rows(step, repetitions, available)
    local target_row = direction < 0 and row - amount or row + amount
    cursor.offset = row_offset(target_row, preferred_col, root, bpr)

    local current_top = M.visible_top(top_row, row, rows, view_height, session.scrolloff or 0)
    local screen_row = row - current_top
    top_row = clamp_top(target_row - screen_row, rows, view_height)
  elseif action == 'WordNext' or action == 'WordPrev' or action == 'WordEnd' then
    preferred_col = nil
    if cursor.area == 'ascii' then
      local captured = {
        generation = session.generation,
        cursor = copy_cursor(session.cursor),
      }
      local co = coroutine.create(function()
        return ascii_word_motion(cursor, root, repetitions, action)
      end)
      local token = {
        co = co,
        root = root,
        generation = captured.generation,
        captured = captured,
        bpr = bpr,
        height = view_height,
        top_row = top_row,
        done = callback,
      }
      pending[session] = token
      local ok, result = coroutine.resume(co)
      if not ok then
        pending[session] = nil
        error(result, 0)
      end
      if coroutine.status(co) == 'dead' then
        pending[session] = nil
        if commit(session, result, preferred_col, top_row, root, bpr, view_height, captured) then
          callback()
        end
      else
        yield(function() finish_pending(session, token) end)
      end
      return
    end
    hex_word_motion(cursor, root, repetitions, action)
  elseif action == 'RowStart' then
    row = floor(cursor.offset / bpr)
    cursor.offset = row * bpr
    if cursor.area == 'hex' then cursor.nibble = 0 end
    preferred_col = nil
  elseif action == 'RowEnd' then
    local target_row = min(rows - 1, row + min(repetitions - 1, rows - 1 - row))
    cursor.offset = row_offset(target_row, bpr - 1, root, bpr)
    if cursor.area == 'hex' then cursor.nibble = 1 end
    preferred_col = nil
  elseif action == 'First' then
    local target_row = has_count and min(repetitions - 1, rows - 1) or 0
    cursor.offset = target_row * bpr
    if cursor.area == 'hex' then cursor.nibble = 0 end
    preferred_col = nil
  elseif action == 'Last' then
    if has_count then
      local target_row = min(repetitions - 1, rows - 1)
      cursor.offset = target_row * bpr
      if cursor.area == 'hex' then cursor.nibble = 0 end
    else
      cursor.offset = root.size - 1
      if cursor.area == 'hex' then cursor.nibble = 1 end
    end
    preferred_col = nil
  else
    error(('motion: unknown action %q'):format(tostring(action)), 2)
  end

  local captured = {
    generation = session.generation,
    cursor = original,
  }
  if commit(session, cursor, preferred_col, top_row, root, bpr, view_height, captured) then
    callback()
  end
end

return M
