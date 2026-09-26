local document = require('hexit.document')
local format = require('hexit.format')
local helpers = require('tests.helpers')

local function case(name, run)
  return { name = name, run = run }
end

local golden_bytes = string.char(0x00, 0x41, 0x7f, 0xff)
local golden = {
  hex = '00 41 7F FF',
  compact = '00417FFF',
  escaped = '\\x00\\x41\\x7F\\xFF',
  c = '{ 0x00, 0x41, 0x7F, 0xFF }',
  cstring = '"\\x00\\x41\\x7F\\xFF"',
  python = 'b"\\x00\\x41\\x7f\\xff"',
  rust = '[0x00, 0x41, 0x7f, 0xff]',
  ascii = '.A..',
  base64 = 'AEF//w==',
}

return {
  case('COPY formats: all nine encoders match stable byte goldens', function()
    for name, expected in pairs(golden) do
      local encoder = format.new(name)
      for index = 1, #golden_bytes do
        encoder:push(golden_bytes:sub(index, index))
        encoder:push('')
      end
      helpers.eq(encoder:finish(), expected)
      helpers.eq(encoder:finish(), expected)
      helpers.eq(format.encode(name, golden_bytes), expected)
    end
  end),

  case('COPY base64: one-, two-, and three-byte tails pad correctly', function()
    local cases = {
      { string.char(0x00), 'AA==' },
      { string.char(0x00, 0x01), 'AAE=' },
      { string.char(0x00, 0x01, 0x02), 'AAEC' },
    }
    for _, item in ipairs(cases) do
      local bytes, expected = item[1], item[2]
      local encoder = format.new('base64')
      for index = 1, #bytes do
        encoder:push(bytes:sub(index, index))
      end
      helpers.eq(encoder:finish(), expected)
      helpers.eq(format.encode('base64', bytes), expected)
    end
  end),

  case('COPY base64: 64KiB document chunks preserve byte alignment', function()
    local byte_values = {}
    for value = 0, 255 do
      byte_values[#byte_values + 1] = string.char(value)
    end
    local bytes = string.rep(table.concat(byte_values), 1024)
    local root = document.from_chunks({ bytes })
    local encoder = format.new('base64')
    local chunks = 0

    for chunk in document.iter(root, 0, root.size, 64 * 1024) do
      chunks = chunks + 1
      encoder:push(chunk)
    end

    helpers.eq(chunks, 4)
    helpers.eq(encoder:finish(), vim.base64.encode(bytes))
  end),
}
