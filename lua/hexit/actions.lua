local document = require('hexit.document')
local view = require('hexit.view')

local M = {}
local register = document.empty()
local LIMIT = 9007199254740991

local function cursor(session)
  return vim.deepcopy(session.cursor)
end

local function changed(session)
  session.revision = session.revision + 1
  session.on_change(session, 'edit')
end

function M.refresh_dirty(session)
  local root, saved = session.root, session.saved_root
  if not root or not saved or session.phase == 'closed' then return end
  local buf = session.bufnr
  if root == saved or root.size == 0 and saved.size == 0 then
    session.dirty_check = nil
    vim.bo[buf].modified = false
    return
  end
  if root.size ~= saved.size then
    session.dirty_check = nil
    vim.bo[buf].modified = true
    return
  end
  vim.bo[buf].modified = true
  local check = session.dirty_check
  if check then
    check.root, check.saved, check.revision, check.at = root, saved, session.revision, 0
    return
  end
  check = { root = root, saved = saved, revision = session.revision, at = 0 }
  session.dirty_check = check
  local function step()
    if session.phase == 'closed' or session.dirty_check ~= check then return end
    local current, baseline, revision = check.root, check.saved, check.revision
    if session.saved_root ~= baseline or session.revision ~= revision then
      session.dirty_check = nil
      return
    end
    local stop = math.min(current.size, check.at + 65536)
    if document.read(current, check.at, stop - check.at)
      ~= document.read(baseline, check.at, stop - check.at) then
      session.dirty_check = nil
      return
    end
    check.at = stop
    if stop == current.size then
      session.dirty_check = nil
      vim.bo[buf].modified = false
    else
      vim.schedule(step)
    end
  end
  vim.schedule(step)
end

function M.selection(session)
  if not session.anchor or session.root.size == 0 then return nil end
  local start, stop
  if session.mode == 'visual_line' then
    local bpr = session.bytes_per_row
    start = math.floor(math.min(session.anchor, session.cursor.offset) / bpr) * bpr
    stop = math.min(session.root.size, (math.floor(math.max(session.anchor, session.cursor.offset) / bpr) + 1) * bpr)
  else
    start = math.min(session.anchor, session.cursor.offset)
    stop = math.max(session.anchor, session.cursor.offset) + 1
  end
  return start, stop
end

function M.escape(session)
  if session.mode == 'replace' then M.commit(session) end
  session.mode, session.anchor, session.eof_after_replace = 'normal', nil, false
  view.render(session)
end

function M.visual(session, mode)
  if session.root.size == 0 then return end
  if session.mode == mode then
    M.escape(session)
  else
    if not session.anchor then session.anchor = session.cursor.offset end
    session.mode = mode
    view.render(session)
  end
end

function M.begin(session)
  assert(not session.transaction, 'hexit: transaction already active')
  session.transaction = { before = session.root, cursor_before = cursor(session), ranges = {} }
end

function M.apply(session, start, remove_len, insert_root)
  local transaction = assert(session.transaction, 'hexit: transaction required')
  session.root = document.splice(session.root, start, remove_len, insert_root)
  transaction.ranges[#transaction.ranges + 1] = { start = start, len = remove_len, insert = insert_root.size }
  changed(session)
  M.refresh_dirty(session)
end
local function apply_replace_mode(session, start, data)
  local transaction = assert(session.transaction, 'hexit: transaction required')
  local run = transaction.run
  local same_byte = run and start == run.stop - 1
  if not run or (start ~= run.stop and start ~= run.stop - 1) then
    local range = { start = start, len = 1, insert = 1 }
    run = { start = start, stop = start + 1, range = range, blocks = {} }
    transaction.run = run
    transaction.ranges[#transaction.ranges + 1] = range
  elseif start == run.stop then
    run.stop = start + 1
    run.range.len, run.range.insert = run.stop - run.start, run.stop - run.start
  end

  local blocks = run.blocks
  if same_byte then
    -- The second nibble overwrites the last Byte; previous roots retain the
    -- old immutable string. Dyadic merges amortize copied data over the run.
    local last = blocks[#blocks]
    blocks[#blocks] = { data = last.data:sub(1, -2) .. data, len = last.len }
  else
    blocks[#blocks + 1] = { data = data, len = 1 }
    while #blocks > 1 and blocks[#blocks].len == blocks[#blocks - 1].len do
      local right = table.remove(blocks)
      local left = table.remove(blocks)
      blocks[#blocks + 1] = { data = left.data .. right.data, len = left.len + right.len }
    end
  end

  local chunks = {}
  for i, block in ipairs(blocks) do chunks[i] = block.data end
  session.root = document.splice(session.root, run.start, run.stop - run.start, document.from_chunks(chunks))
end


function M.commit(session)
  local transaction = session.transaction
  if not transaction then return end
  session.transaction = nil
  local before, after = transaction.before, session.root
  if before == after then return end
  local entry = {
    before = before, after = after, cursor_before = transaction.cursor_before, cursor_after = cursor(session),
  }
  local function record()
    session.undo[#session.undo + 1] = entry
    session.redo = {}
  end
  if before.size ~= after.size then record(); return end
  -- A no-op replacement keeps redo. Compare touched ranges in bounded slices;
  -- while pending, another edit must not race history finalization.
  local ranges, index, position = transaction.ranges, 1, 0
  local revision = session.revision
  local function compare()
    local deadline = vim.uv.hrtime() + 8 * 1000000
    local budget = 65536
    while index <= #ranges and budget > 0 and vim.uv.hrtime() < deadline do
      local range = ranges[index]
      if range.len ~= range.insert then
        session.pending = nil
        record()
        return
      end
      local take = math.min(range.len - position, budget)
      if take > 0 then
        if document.read(before, range.start + position, take) ~= document.read(after, range.start + position, take) then
          session.pending = nil
          record()
          return
        end
        position, budget = position + take, budget - take
      end
      if position == range.len then index, position = index + 1, 0 end
    end
    if index > #ranges then
      session.pending = nil
      M.refresh_dirty(session)
      return
    end
    session.pending = 'comparing edit'
    vim.schedule(function()
      if session.phase ~= 'closed' and session.revision == revision then compare() end
    end)
  end
  compare()
end

local function replace_root(data)
  return document.from_chunks({ data })
end

local function fill_root(byte, len)
  local chunks, block = {}, string.rep(string.char(byte), 65536)
  while len > 0 do
    local take = math.min(len, 65536)
    chunks[#chunks + 1] = take == 65536 and block or block:sub(1, take)
    len = len - take
  end
  return document.from_chunks(chunks)
end

local function count_check(start, count, size)
  return count > 0 and start <= size and count <= size - start
end

function M.replace(session, value, count)
  local root, cur = session.root, session.cursor
  if session.mode == 'visual' or session.mode == 'visual_line' then
    local start, stop = M.selection(session)
    if not start then return false, 'empty selection' end
    local byte = cur.area == 'hex' and tonumber(value, 16) or value:byte()
    if not byte then return false, 'expected a hex Byte' end
    M.begin(session)
    M.apply(session, start, stop - start, fill_root(byte, stop - start))
    session.cursor.offset, session.cursor.nibble = start, 0
    session.mode, session.anchor = 'normal', nil
    M.commit(session)
    view.render(session)
    return true
  end
  local start, length, result
  if cur.area == 'hex' then
    local advance = math.floor((cur.nibble + count - 1) / 2)
    if count < 1 or advance >= root.size - cur.offset then return false, 'replace exceeds EOF' end
    local first_byte, last_byte = cur.offset, cur.offset + advance
    local digit = tonumber(value, 16)
    if not digit then return false, 'expected a hex digit' end
    local chunks, offset = {}, first_byte
    for chunk in document.iter(root, first_byte, last_byte - first_byte + 1, 65536) do
      local within = 0
      chunks[#chunks + 1] = chunk:gsub('.', function(char)
        local old = char:byte()
        local pos = (offset - first_byte + within) * 2 - cur.nibble
        within = within + 1
        if pos >= 0 and pos < count then
          old = old % 16 + digit * 16
        end
        if pos + 1 >= 0 and pos + 1 < count then
          old = old - old % 16 + digit
        end
        return string.char(old)
      end)
      offset = offset + #chunk
    end
    start, length, result = first_byte, last_byte - first_byte + 1, document.from_chunks(chunks)
    M.begin(session)
    cur.offset, cur.nibble = last_byte, (cur.nibble + count - 1) % 2
  else
    start, length = cur.offset, count
    if not count_check(start, count, root.size) then return false, 'replace exceeds EOF' end
    result = fill_root(value:byte(), count)
    M.begin(session)
    cur.offset = start + count - 1
  end
  M.apply(session, start, length, result)
  M.commit(session)
  view.render(session)
  return true
end

function M.replace_mode(session, value)
  local cur, size = session.cursor, session.root.size
  if session.eof_after_replace or size == 0 then return false, 'replace exceeds EOF' end
  local start = cur.offset
  local data
  if cur.area == 'hex' then
    local previous = document.read(session.root, start, 1):byte()
    local digit = tonumber(value, 16)
    if not digit then return false, 'expected a hex digit' end
    data = string.char(cur.nibble == 0 and (previous % 16 + digit * 16) or (previous - previous % 16 + digit))
  else
    data = value
  end
  apply_replace_mode(session, start, data)
  if cur.area == 'hex' and cur.nibble == 0 then
    cur.nibble = 1
  elseif start + 1 < size then
    cur.offset = start + 1
    cur.nibble = 0
  else
    session.eof_after_replace = true
  end
  changed(session)
  M.refresh_dirty(session)
  return true
end

function M.yank(session, count)
  if session.root.size == 0 then return false, 'empty file' end
  local start, stop = M.selection(session)
  if not start then
    start = session.cursor.offset
    stop = math.min(session.root.size, start + count)
  end
  register = document.slice(session.root, start, stop - start)
  if session.anchor then
    session.cursor.offset, session.cursor.nibble = start, 0
    M.escape(session)
  end
  return true
end

local function repeat_root(root, count)
  if count > math.floor(LIMIT / root.size) then return nil end
  local pieces, ends, total = {}, {}, 0
  if root.size <= 65536 then
    -- Expand tiny registers once per 64KiB block, not once per copied Byte.
    local source = document.read(root, 0, root.size)
    local per_block = math.min(count, math.floor(65536 / root.size))
    local block = string.rep(source, per_block)
    local full = math.floor(count / per_block)
    for _ = 1, full do
      total = total + #block
      pieces[#pieces + 1] = { data = block, start = 0, len = #block }
      ends[#ends + 1] = total
    end
    local rest = count % per_block
    if rest > 0 then
      local tail = string.rep(source, rest)
      total = total + #tail
      pieces[#pieces + 1] = { data = tail, start = 0, len = #tail }
      ends[#ends + 1] = total
    end
  else
    -- Large register pieces already share their immutable backing strings.
    for _ = 1, count do
      for _, piece in ipairs(root.pieces) do
        total = total + piece.len
        pieces[#pieces + 1] = { data = piece.data, start = piece.start, len = piece.len }
        ends[#ends + 1] = total
      end
    end
  end
  return { pieces = pieces, ends = ends, size = total }
end

function M.paste(session, after, count)
  if session.anchor then return false, 'paste in Visual is not supported' end
  if register.size == 0 then return false, 'binary register is empty' end
  if count > math.floor((LIMIT - session.root.size) / register.size) then
    return false, 'paste exceeds maximum size'
  end
  local repeated = repeat_root(register, count)
  local start = session.root.size == 0 and 0 or session.cursor.offset + (after and 1 or 0)
  M.begin(session)
  M.apply(session, start, 0, repeated)
  session.cursor.offset, session.cursor.nibble = start, 0
  M.commit(session)
  view.render(session)
  return true
end

function M.history(session, redo, count)
  if session.anchor then M.escape(session) end
  local source, dest = redo and session.redo or session.undo, redo and session.undo or session.redo
  local changed_any = false
  for _ = 1, math.min(count, #source) do
    local entry = table.remove(source)
    dest[#dest + 1] = entry
    session.root = redo and entry.after or entry.before
    session.cursor = vim.deepcopy(redo and entry.cursor_after or entry.cursor_before)
    session.cursor.offset = math.min(session.cursor.offset, math.max(0, session.root.size - 1))
    session.revision = session.revision + 1
    changed_any = true
  end
  if changed_any then
    M.refresh_dirty(session)
    view.render(session)
  end
end

function M.copy_as(session, name, target)
  local format = require('hexit.format')
  if target ~= '+' and target ~= '*' and target ~= '"' then
    error('hexit: Copy As register must be +, * or "', 2)
  end
  local encoder = format.new(name)
  local start, stop = M.selection(session)
  if not start then
    start, stop = session.cursor.offset, math.min(session.cursor.offset + 1, session.root.size)
  end
  if start == stop then error('hexit: no Byte to copy', 2) end
  if target ~= '"' then
    local provider = vim.fn['provider#clipboard#Executable']()
    if provider == 0 or provider == '' then
      error('hexit: system clipboard provider is unavailable', 2)
    end
  end
  local root, revision = session.root, session.revision
  local iterator = document.iter(root, start, stop - start, 65536)
  local function step()
    if session.phase == 'closed' or session.revision ~= revision then return end
    local chunk = iterator()
    if chunk then
      encoder:push(chunk)
      vim.schedule(step)
    else
      local ok, err = pcall(vim.fn.setreg, target, encoder:finish(), 'v')
      if not ok then vim.notify('hexit: Copy As failed: ' .. tostring(err), vim.log.levels.ERROR) end
    end
  end
  vim.schedule(step)
end

function M.register() return register end

return M
