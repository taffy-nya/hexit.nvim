local document = require('hexit.document')
local message = require('hexit.message')

local M = {}
local BLOCK = 64 * 1024
local MAX_SAFE_INTEGER = 9007199254740991
local min = math.min
local max = math.max
local floor = math.floor
local byte = string.byte

-- Cooperative steps must return to the event loop between slices: a
-- self-rescheduling vim.schedule chain drains in a single burst and starves
-- libuv timers, so a 50 MiB scan would block timers and loop polling for its
-- whole duration. A zero-delay timer yields a real loop turn instead.
local function schedule(callback)
  vim.defer_fn(callback, 0)
end

local function now()
  return vim.uv.hrtime()
end

local function folded(value, enabled)
  if enabled and value >= 65 and value <= 90 then return value + 32 end
  return value
end

local function pattern_byte(query, index)
  return folded(byte(query.bytes, index), query.fold)
end

local function add_within_size(size, position, amount)
  local remaining = size - position
  if amount >= remaining then return size end
  return position + amount
end

local function hex_value(value)
  if value >= 48 and value <= 57 then return value - 48 end
  if value >= 65 and value <= 70 then return value - 55 end
  if value >= 97 and value <= 102 then return value - 87 end
end

local function parse_hex(text)
  if text == '' then return nil, 'search pattern must not be empty' end
  local chunks, pending = {}, {}
  local count, pending_count = 0, 0
  local function append(value)
    pending_count = pending_count + 1
    pending[pending_count] = string.char(value)
    count = count + 1
    if pending_count == 4096 then
      chunks[#chunks + 1] = table.concat(pending)
      pending, pending_count = {}, 0
    end
  end
  local function result()
    if pending_count > 0 then chunks[#chunks + 1] = table.concat(pending) end
    return table.concat(chunks)
  end

  if not text:find('%s') then
    local pair = text:match('^[0][xX]([%da-fA-F][%da-fA-F])$')
    if pair then
      append(hex_value(byte(pair, 1)) * 16 + hex_value(byte(pair, 2)))
    else
      if #text % 2 ~= 0 then return nil, 'hex search pattern must contain complete byte pairs' end
      for index = 1, #text, 2 do
        local high = hex_value(byte(text, index))
        local low = hex_value(byte(text, index + 1))
        if high == nil or low == nil then return nil, 'invalid hex search pattern' end
        append(high * 16 + low)
      end
    end
  else
    for token in text:gmatch('%S+') do
      local pair = token:match('^[0][xX]([%da-fA-F][%da-fA-F])$')
        or token:match('^([%da-fA-F][%da-fA-F])$')
      if not pair then return nil, 'hex search pattern must contain whitespace-delimited byte pairs' end
      append(hex_value(byte(pair, 1)) * 16 + hex_value(byte(pair, 2)))
    end
    if count == 0 then return nil, 'search pattern must not be empty' end
  end

  return result()
end

function M.parse(kind, text, opts)
  if kind ~= 'hex' and kind ~= 'ascii' then
    return nil, 'search type must be hex or ascii'
  end
  if type(text) ~= 'string' then return nil, 'search pattern must be a string' end

  local bytes
  local has_uppercase = false
  if kind == 'hex' then
    local err
    bytes, err = parse_hex(text)
    if not bytes then return nil, err end
  else
    if #text == 0 then return nil, 'search pattern must not be empty' end
    for index = 1, #text do
      local value = byte(text, index)
      if value < 32 or value > 126 then
        return nil, 'ASCII search supports printable ASCII bytes only; use Hex search for binary data'
      end
      if value >= 65 and value <= 90 then has_uppercase = true end
    end
    bytes = text
  end

  opts = opts or {}
  local ignorecase = opts.search_ignorecase
  if ignorecase == nil then ignorecase = vim.o.ignorecase end
  local smartcase = opts.search_smartcase
  if smartcase == nil then smartcase = vim.o.smartcase end
  local fold = kind == 'ascii' and ignorecase == true
    and not (smartcase == true and has_uppercase)

  local query = { bytes = bytes, kind = kind, fold = fold }
  if #bytes == 1 then query._prefix = { 0 } end
  return query
end

local function cancel_task(task)
  if not task then return end
  task.cancelled = true
  task.scanner = nil
  task.on_done = nil
end

local function cancel_prefix_build(query, build)
  if query._prefix_build ~= build then return end
  build.cancelled = true
  build.step = nil
  build.values = nil
  build.waiters = {}
  query._prefix_build = nil
end

local function detach_prefix_record(state, record)
  if not record then return end
  state._prefix_records[record] = nil
  record.callback = nil
  local query = record.query
  local build = query._prefix_build
  if build and build.waiters[record] then
    build.waiters[record] = nil
    if next(build.waiters) == nil then cancel_prefix_build(query, build) end
  end
end

local function deliver_prefix(record, prefix)
  schedule(function()
    local callback = record.callback
    record.callback = nil
    if callback then callback(prefix) end
  end)
end

local function finish_prefix_build(query, build)
  if query._prefix_build ~= build or build.cancelled then return end
  local waiters = build.waiters
  local prefix = build.values
  query._prefix = prefix
  query._prefix_build = nil
  build.values, build.waiters, build.step = nil, {}, nil
  for record in pairs(waiters) do
    waiters[record] = nil
    deliver_prefix(record, prefix)
  end
end

local function drive_prefix_build(query, build)
  if build.cancelled or query._prefix_build ~= build then return end
  local index, matched, values = build.index, build.matched, build.values
  local length = #query.bytes
  local work = 0
  local deadline = now() + 8 * 1000000

  while index <= length and work < BLOCK do
    if matched > 0 and pattern_byte(query, matched + 1) ~= pattern_byte(query, index) then
      matched = values[matched]
      work = work + 1
    else
      if pattern_byte(query, matched + 1) == pattern_byte(query, index) then
        matched = matched + 1
      end
      values[index] = matched
      index = index + 1
      work = work + 1
    end
    if work % 256 == 0 and now() >= deadline then break end
  end

  build.index, build.matched = index, matched
  if index > length then
    finish_prefix_build(query, build)
  else
    schedule(function()
      if build.step then build.step(query, build) end
    end)
  end
end

local function ensure_prefix(state, callback)
  local query = state.query
  if query._prefix then
    callback(query._prefix)
    return
  end

  local record = { query = query }
  record.callback = function(prefix)
    state._prefix_records[record] = nil
    if state._generation == record.generation
      and state.query == query
      and state._root == record.root
      and state._revision == record.revision then
      callback(prefix)
    end
  end
  record.generation, record.root, record.revision = state._generation, state._root, state._revision
  state._prefix_records[record] = true

  local build = query._prefix_build
  if not build then
    build = { index = 2, matched = 0, values = { 0 }, waiters = {}, cancelled = false }
    query._prefix_build = build
    build.step = drive_prefix_build
  end
  build.waiters[record] = true
  if build.index == 2 and #query.bytes == 1 then
    query._prefix = build.values
    query._prefix_build = nil
    build.values, build.waiters, build.step = nil, {}, nil
    deliver_prefix(record, query._prefix)
  elseif build.index == 2 and not build.running then
    build.running = true
    schedule(function()
      if build.step then build.step(query, build) end
    end)
  end
end

local function live(session, state, generation)
  return session.phase ~= 'closed'
    and session.search == state
    and state._generation == generation
    and session.root == state._root
    and session.revision == state._revision
end

local function new_scanner(root, start, stop, query, prefix, on_hit)
  return {
    iterator = document.iter(root, start, stop - start, BLOCK),
    position = start,
    stop = stop,
    query = query,
    prefix = prefix,
    on_hit = on_hit,
    chunk = nil,
    chunk_index = 1,
    pending_byte = nil,
    matched = 0,
    halted = false,
  }
end

local function scanner_step(scanner)
  local work = 0
  local deadline = now() + 8 * 1000000
  local length = #scanner.query.bytes

  while scanner.position < scanner.stop and not scanner.halted and work < BLOCK do
    if scanner.pending_byte == nil then
      if not scanner.chunk or scanner.chunk_index > #scanner.chunk then
        scanner.chunk = scanner.iterator()
        scanner.chunk_index = 1
        if not scanner.chunk then
          scanner.position = scanner.stop
          break
        end
      end
      scanner.pending_byte = folded(byte(scanner.chunk, scanner.chunk_index), scanner.query.fold)
    end

    local matched = scanner.matched
    if matched > 0 and pattern_byte(scanner.query, matched + 1) ~= scanner.pending_byte then
      scanner.matched = scanner.prefix[matched]
      work = work + 1
    else
      if pattern_byte(scanner.query, matched + 1) == scanner.pending_byte then
        matched = matched + 1
        scanner.matched = matched
      end
      local hit = scanner.position - length + 1
      scanner.position = scanner.position + 1
      scanner.chunk_index = scanner.chunk_index + 1
      scanner.pending_byte = nil
      work = work + 1
      if matched == length then
        scanner.matched = scanner.prefix[length]
        if scanner.on_hit and scanner.on_hit(scanner, hit) then scanner.halted = true end
      end
    end

    if work % 256 == 0 and now() >= deadline then break end
  end

  return scanner.halted or scanner.position >= scanner.stop
end

local function drive_task(task, synchronous)
  if task.cancelled then return end
  if scanner_step(task.scanner) then
    local callback = task.on_done
    task.scanner, task.on_done, task.cancelled = nil, nil, true
    if callback then callback(synchronous == true) end
  else
    schedule(function()
      if not task.cancelled then drive_task(task, false) end
    end)
  end
end

local function make_task(scanner, on_done)
  return { scanner = scanner, on_done = on_done, cancelled = false }
end

local function start_task(task, synchronous)
  if synchronous then
    drive_task(task, true)
  else
    schedule(function()
      if not task.cancelled then drive_task(task, false) end
    end)
  end
end
local function detach_prefix_records_for_state(state)
  local records = {}
  for record in pairs(state._prefix_records) do records[#records + 1] = record end
  for _, record in ipairs(records) do detach_prefix_record(state, record) end
end

local function index_for(root, counts, total)
  local blocks = math.ceil(root.size / BLOCK)
  local cumulative = {}
  local sum = 0
  for block = 1, blocks do
    sum = sum + (counts[block] or 0)
    cumulative[block] = sum
  end
  return {
    root = root,
    revision = nil,
    block_counts = counts,
    cumulative = cumulative,
    blocks = blocks,
    total = total,
  }
end

local function notify(session, state, generation)
  if not live(session, state, generation) or type(session.on_change) ~= 'function' then return end
  session.on_change(session, 'search')
end

local function cancel_navigation(state)
  cancel_task(state._navigation_task)
  state._navigation_task = nil
end

local begin_navigation

local function finish_index(session, state, generation, counts, total, cursor_rank)
  if not live(session, state, generation) then return end
  local index = index_for(state._root, counts, total)
  index.revision = state._revision
  state.index, state.total = index, total
  state._index_task = nil

  if state._request then
    state.pending = true
    notify(session, state, generation)
    begin_navigation(session, state, generation, state._request)
    return
  end

  state.pending = false
  state.current = cursor_rank and state._rebuild_cursor or nil
  state.ordinal = cursor_rank or (total == 0 and 0 or nil)
  state.wrapped = false
  state._rebuild_cursor = nil
  notify(session, state, generation)
end

local function start_index_scan(session, state, generation)
  if not live(session, state, generation) or state._index_task then return end
  local root, query = state._root, state.query
  local counts, total = {}, 0
  local block, block_start, block_count = 1, 0, 0
  local cursor_rank
  local cursor_target = state._rebuild_cursor

  local function scan(prefix)
    if not live(session, state, generation) or state._index_task then return end
    local scan_stop = #query.bytes > root.size and 0 or root.size
    local scanner = new_scanner(root, 0, scan_stop, query, prefix, function(_, hit)
      while hit - block_start >= BLOCK do
        counts[block] = block_count
        block, block_start, block_count = block + 1, block_start + BLOCK, 0
      end
      block_count = block_count + 1
      total = total + 1
      if cursor_target ~= nil and hit == cursor_target then cursor_rank = total end
    end)
    local task
    task = make_task(scanner, function()
      if state._index_task == task then state._index_task = nil end
      if root.size > 0 then counts[block] = block_count end
      finish_index(session, state, generation, counts, total, cursor_rank)
    end)
    state._index_task = task
    start_task(task, false)
  end

  if #query.bytes > root.size then
    scan(nil)
  else
    ensure_prefix(state, scan)
  end
end

local function ensure_index(session, state, generation)
  if state.index and state.index.root == state._root and state.index.revision == state._revision then
    return
  end
  start_index_scan(session, state, generation)
end

local function set_cursor(session, state, offset)
  session.cursor.offset = offset
  session.cursor.nibble = 0
  if state.query.kind == 'hex' then session.cursor.area = 'hex' end
  session.preferred_col = nil
end

local function request_is_live(session, state, generation, request)
  return live(session, state, generation) and state._request == request
end

local function finish_navigation(session, state, generation, request, offset, rank, wrapped)
  if not request_is_live(session, state, generation, request) then return end
  state._navigation_task = nil
  state._request = nil
  state.current, state.ordinal, state.wrapped = offset, rank, wrapped
  state.pending = false
  set_cursor(session, state, offset)
  notify(session, state, generation)
  if wrapped then
    local text = request.direction == 1
      and 'search hit BOTTOM, continuing at TOP'
      or 'search hit TOP, continuing at BOTTOM'
    message.show(text, 'ModeMsg')
  end
end

local function target_rank(session, state, generation, request, prefix_count)
  if not request_is_live(session, state, generation, request) then return end
  local total = state.total
  if total == 0 then
    state._request = nil
    state.pending = false
    state.current, state.ordinal, state.wrapped = nil, 0, false
    notify(session, state, generation)
    message.show('Pattern not found')
    return
  end

  local requested_count = request.count
  local count = (requested_count - 1) % total + 1
  local rank, wrapped
  if request.direction == 1 then
    local after = total - prefix_count
    if count <= after then
      rank, wrapped = prefix_count + count, requested_count > after
    else
      rank, wrapped = count - after, requested_count > after
    end
  elseif count <= prefix_count then
    rank, wrapped = prefix_count - count + 1, requested_count > prefix_count
  else
    rank, wrapped = total - (count - prefix_count) + 1, requested_count > prefix_count
  end

  local index = state.index
  local low, high = 1, index.blocks
  while low < high do
    local middle = floor((low + high) / 2)
    if index.cumulative[middle] >= rank then high = middle else low = middle + 1 end
  end
  local block = low
  local before = block > 1 and index.cumulative[block - 1] or 0
  local local_rank = rank - before
  local block_start = (block - 1) * BLOCK
  local block_stop = add_within_size(index.root.size, block_start, BLOCK)
  local scan_stop = add_within_size(index.root.size, block_stop, #state.query.bytes - 1)
  local seen, selected = 0, nil
  local scanner = new_scanner(index.root, block_start, scan_stop, state.query,
    state.query._prefix, function(_, hit)
      if hit >= block_start and hit < block_stop then
        seen = seen + 1
        if seen == local_rank then
          selected = hit
          return true
        end
      end
    end)
  local task
  task = make_task(scanner, function()
    if state._navigation_task == task then state._navigation_task = nil end
    if selected ~= nil then
      finish_navigation(session, state, generation, request, selected, rank, wrapped)
    elseif request_is_live(session, state, generation, request) then
      state._request, state.pending = nil, false
      state.current, state.ordinal, state.wrapped = nil, nil, false
      notify(session, state, generation)
    end
  end)
  state._navigation_task = task
  start_task(task, false)
end

local function count_before(session, state, generation, request, position, callback)
  local index = state.index
  local root = index.root
  if position <= 0 then callback(0); return end
  if position >= root.size then callback(index.total); return end

  local block_zero = floor(position / BLOCK)
  local within = position - block_zero * BLOCK
  local preceding = block_zero > 0 and index.cumulative[block_zero] or 0
  if within == 0 then callback(preceding); return end

  local block_start = block_zero * BLOCK
  local scan_stop = add_within_size(root.size, position, #state.query.bytes - 1)
  local local_count = 0
  local scanner = new_scanner(root, block_start, scan_stop, state.query,
    state.query._prefix, function(_, hit)
      if hit < position then local_count = local_count + 1 end
    end)
  local task
  task = make_task(scanner, function()
    if state._navigation_task == task then state._navigation_task = nil end
    if request_is_live(session, state, generation, request) then
      callback(preceding + local_count)
    end
  end)
  state._navigation_task = task
  start_task(task, false)
end

begin_navigation = function(session, state, generation, request)
  if not request_is_live(session, state, generation, request) then return end
  cancel_navigation(state)
  state.pending = true
  local root = state._root
  local position = request.direction == 1
    and min(root.size, request.from + 1)
    or max(0, request.from)

  count_before(session, state, generation, request, position, function(prefix_count)
    if not request_is_live(session, state, generation, request) then return end
    target_rank(session, state, generation, request, prefix_count)
  end)
end

local function validate_direction(direction)
  if direction ~= 1 and direction ~= -1 then error('search direction must be 1 or -1', 3) end
end

local function validate_count(count)
  if count == nil then return 1 end
  if type(count) ~= 'number' or count ~= count or count < 1
    or count > MAX_SAFE_INTEGER or floor(count) ~= count then
    error('search count must be a positive safe integer', 3)
  end
  return count
end

local function make_state(session, query, direction)
  return {
    query = query,
    direction = direction,
    total = nil,
    pending = false,
    visible = true,
    current = nil,
    ordinal = nil,
    wrapped = false,
    index = nil,
    _root = session.root,
    _revision = session.revision,
    _generation = 1,
    _prefix_records = {},
  }
end

local function stop_state(state)
  if not state then return end
  state._generation = state._generation + 1
  cancel_task(state._index_task)
  cancel_navigation(state)
  cancel_task(state._visible_task)
  state._index_task, state._visible_task = nil, nil
  state._visible_request = nil
  detach_prefix_records_for_state(state)
  state._visible_cache = nil
end

function M.start(session, query, direction, count)
  validate_direction(direction)
  count = validate_count(count)
  if type(query) ~= 'table' or type(query.bytes) ~= 'string' or #query.bytes == 0
    or (query.kind ~= 'hex' and query.kind ~= 'ascii') then
    error('search.start requires a parsed non-empty query', 2)
  end
  if not session.root then error('search.start requires a ready document', 2) end

  stop_state(session.search)
  local state = make_state(session, query, direction)
  state._request = {
    direction = direction,
    count = count,
    from = session.cursor.offset,
  }
  state.pending = true
  session.search = state
  local generation = state._generation
  notify(session, state, generation)
  ensure_index(session, state, generation)
end

function M.next(session, direction, count)
  local state = session.search
  if not state or not state.query or not session.root then return end
  validate_direction(direction)
  count = validate_count(count)
  local generation = state._generation
  cancel_navigation(state)
  state.visible = true
  state._visible_cache = nil
  local request = {
    direction = direction,
    count = count,
    from = session.cursor.offset,
  }
  state._request = request
  state.pending = true
  notify(session, state, generation)
  ensure_index(session, state, generation)
  if state.index then begin_navigation(session, state, generation, request) end
end

function M.suspend_navigation(session)
  local state = session.search
  if not state or not state.query then return end
  cancel_navigation(state)
  state._request = nil
  local index = state.index
  local indexed = index and index.root == session.root and index.revision == session.revision
  state.pending = state.visible and not indexed
  notify(session, state, state._generation)
  if state.visible and not indexed then
    ensure_index(session, state, state._generation)
  end
end

function M.cancel(session)
  local state = session.search
  if not state or not state.query or not state.visible then return end
  local index = state.index
  local indexed = index and index.root == session.root and index.revision == session.revision
  stop_state(state)
  state.visible = false
  state.pending = false
  state._request = nil
  state.current, state.ordinal, state.wrapped = nil, nil, false
  state._rebuild_cursor = nil
  if not indexed then
    state.index, state.total = nil, nil
  end
  notify(session, state, state._generation)
end

function M.reset(session)
  stop_state(session.search)
  session.search = nil
end

function M.on_edit(session)
  local previous = session.search
  if not previous or not previous.query or not session.root then return end
  local query, direction, visible = previous.query, previous.direction, previous.visible
  stop_state(previous)
  local state = make_state(session, query, direction)
  state.visible = visible
  state.pending = visible
  if visible then state._rebuild_cursor = session.cursor.offset end
  session.search = state
  if visible then ensure_index(session, state, state._generation) end
end

local function prioritize_visible_ranges(ranges, current, start, stop, pattern_length)
  if current == nil then return ranges end
  local current_start, current_stop = max(start, current), min(stop, current + pattern_length)
  if current_start >= current_stop then return ranges end
  local result = {}
  for _, range in ipairs(ranges) do
    if range.stop <= current_start or range.start >= current_stop then
      result[#result + 1] = range
    else
      if range.start < current_start then
        result[#result + 1] = { start = range.start, stop = current_start, current = false }
      end
      result[#result + 1] = {
        start = max(range.start, current_start), stop = min(range.stop, current_stop), current = true,
      }
      if range.stop > current_stop then
        result[#result + 1] = { start = current_stop, stop = range.stop, current = false }
      end
    end
  end
  return result
end

function M.visible_matches(session, start, stop)
  local state = session.search
  local root = session.root
  if not state or not state.query or not state.visible or not root or state._root ~= root
    or state._revision ~= session.revision or session.phase == 'closed' then return {} end
  if type(start) ~= 'number' or type(stop) ~= 'number' then return {} end
  start = min(root.size, max(0, floor(start)))
  stop = min(root.size, max(0, floor(stop)))
  if stop <= start or #state.query.bytes > root.size then return {} end

  local cache = state._visible_cache
  if cache and cache.root == root and cache.revision == session.revision
    and cache.query == state.query and cache.start == start and cache.stop == stop
    and cache.current == state.current then
    return cache.matches
  end
  state._visible_cache = nil

  local request = state._visible_request
  if request and request.root == root and request.revision == session.revision
    and request.query == state.query and request.start == start and request.stop == stop then
    return {}
  end
  cancel_task(state._visible_task)
  state._visible_task = nil
  request = {
    root = root, revision = session.revision, query = state.query,
    start = start, stop = stop,
  }
  state._visible_request = request
  local generation = state._generation
  local prefix_ready = state.query._prefix ~= nil
  local function scan(prefix)
    if not live(session, state, generation) then return end
    local query = state.query
    local pattern_length = #query.bytes
    local scan_start = max(0, start - pattern_length + 1)
    local scan_stop = add_within_size(root.size, stop, pattern_length - 1)
    local ranges = {}
    local scanner = new_scanner(root, scan_start, scan_stop, query, prefix, function(_, hit)
      if hit < stop and hit + pattern_length > start then
        local first, last = max(start, hit), min(stop, hit + pattern_length)
        local previous = ranges[#ranges]
        if previous and first <= previous.stop then
          previous.stop = max(previous.stop, last)
        else
          ranges[#ranges + 1] = { start = first, stop = last, current = false }
        end
      end
    end)
    local synchronous = prefix_ready and pattern_length <= 4096
      and scan_stop - scan_start <= 4096
    local task
    task = make_task(scanner, function(was_sync)
      if state._visible_task == task then state._visible_task = nil end
      if not live(session, state, generation) or state._visible_request ~= request then return end
      local matches = prioritize_visible_ranges(ranges, state.current, start, stop, pattern_length)
      state._visible_cache = {
        root = root, revision = session.revision, query = query,
        start = start, stop = stop, current = state.current, matches = matches,
      }
      state._visible_request = nil
      if not was_sync then notify(session, state, generation) end
    end)
    state._visible_task = task
    start_task(task, synchronous)
  end

  ensure_prefix(state, scan)
  cache = state._visible_cache
  if cache and cache.root == root and cache.revision == session.revision
    and cache.query == state.query and cache.start == start and cache.stop == stop
    and cache.current == state.current then
    return cache.matches
  end
  return {}
end

return M
