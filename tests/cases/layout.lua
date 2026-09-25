local document = require('hexit.document')
local layout = require('hexit.layout')
local helpers = require('tests.helpers')

local function case(name, run)
  return { name = name, run = run }
end

local function assert_cursor(actual, offset, nibble, area)
  helpers.eq(actual, { offset = offset, nibble = nibble, area = area })
end

return {
  case('VIEW layout: binary row formatting and stable columns', function()
    local bytes = helpers.bytes(0x00, 0x20, 0x41, 0x7e, 0x7f, 0x80, 0xff)
    local root = document.from_chunks({ bytes })
    local computed = layout.compute({ bytes_per_row = 8, byte_group_size = 2 }, 80, root.size)

    helpers.eq(computed.hex_start, 10)
    helpers.eq(computed.ascii_start, 31)
    helpers.eq(computed.offset_width, 8)
    helpers.eq(computed.width, 39)
    helpers.eq(layout.row(root, 0, computed),
      '00000000  0020 417E 7F80 FF    . A~... ')

    helpers.eq(layout.row(root, 1, computed), '')
  end),

  case('VIEW layout: cells round-trip across byte groups and row widths', function()
    for _, bpr in ipairs({ 8, 16, 32 }) do
      for _, group in ipairs({ 1, 2, 4 }) do
        local root = document.from_chunks({ string.rep('x', bpr * 4) })
        local computed = layout.compute({
          bytes_per_row = bpr,
          byte_group_size = group,
        }, 120, root.size)
        local offset = bpr * 2

        for byte_col = 0, bpr - 1 do
          for nibble = 0, 1 do
            local screen_col = layout.cell(computed, byte_col, nibble, 'hex')
            assert_cursor(layout.hit(computed, 3, screen_col, 1, root.size), offset + byte_col, nibble, 'hex')
          end
          local ascii_col = layout.cell(computed, byte_col, 0, 'ascii')
          assert_cursor(layout.hit(computed, 3, ascii_col, 1, root.size), offset + byte_col, 0, 'ascii')
        end

        local separator_after = group - 1
        local separator = layout.cell(computed, separator_after, 1, 'hex') + 1
        assert_cursor(layout.hit(computed, 3, separator, 1, root.size), offset + separator_after, 1, 'hex')
      end
    end
  end),

  case('VIEW layout: header, gaps, padding, and ASCII spaces are hit safely', function()
    local bytes = helpers.bytes(0x00, 0x20, 0x41, 0x7e, 0x7f, 0x80, 0xff, 0x11, 0x20)
    local root = document.from_chunks({ bytes })
    local computed = layout.compute({ bytes_per_row = 8, byte_group_size = 2 }, 80, root.size)

    helpers.eq(layout.hit(computed, 1, computed.hex_start, 0, root.size), nil)
    helpers.eq(layout.hit(computed, 2, 0, 0, root.size), nil)
    helpers.eq(layout.hit(computed, 2, computed.ascii_start - 1, 0, root.size), nil)
    helpers.eq(layout.hit(computed, 2, layout.cell(computed, 0, 0, 'hex'), 0, root.size),
      { offset = 0, nibble = 0, area = 'hex' })

    helpers.eq(layout.hit(computed, 3, layout.cell(computed, 1, 0, 'hex'), 0, root.size), nil)
    assert_cursor(layout.hit(computed, 3, layout.cell(computed, 0, 0, 'ascii'), 0, root.size), 8, 0, 'ascii')
    helpers.eq(layout.hit(computed, 3, layout.cell(computed, 1, 0, 'ascii'), 0, root.size), nil)
    helpers.eq(layout.hit(computed, 4, layout.cell(computed, 0, 0, 'ascii'), 0, root.size), nil)
  end),

  case('VIEW layout: auto thresholds and fixed-width overflow', function()
    local opts = { bytes_per_row = 'auto', byte_group_size = 4 }
    local expected = {
      { 37, 8 }, { 36, 8 }, { 63, 16 }, { 62, 8 }, { 115, 32 }, { 114, 16 },
    }
    for _, threshold in ipairs(expected) do
      local computed = layout.compute(opts, threshold[1], 32)
      helpers.eq(computed.bpr, threshold[2], 'auto BPR at width ' .. threshold[1])
    end

    local tiny = layout.compute({ bytes_per_row = 'auto' }, 1, 1)
    helpers.eq(tiny.bpr, 8)
    local fixed = layout.compute({ bytes_per_row = 32 }, 1, 1)
    helpers.eq(fixed.bpr, 32)
    helpers.eq(fixed.width > 1, true)

    local no_sections = layout.compute({
      bytes_per_row = 'auto', byte_group_size = 4, show_offset = false, show_ascii = false,
    }, 71, 32)
    helpers.eq(no_sections.bpr, 32)
    helpers.eq(no_sections.hex_start, 0)
    helpers.eq(no_sections.width, 71)
  end),

  case('VIEW layout: offset width, casing, and display toggles', function()
    local eight_digits = layout.compute({ bytes_per_row = 8 }, 80, 0x100000000)
    local nine_digits = layout.compute({ bytes_per_row = 8 }, 80, 0x100000001)
    helpers.eq(eight_digits.offset_width, 8)
    helpers.eq(nine_digits.offset_width, 9)

    local bytes = helpers.bytes(0x00, 0xff, 0x00, 0x20, 0x7e, 0x7f, 0x80, 0xff)
    local root = document.from_chunks({ bytes .. string.rep(string.char(0), 0xa9) })
    local lower = layout.compute({
      bytes_per_row = 8, byte_group_size = 4, uppercase_hex = false,
      show_offset = false, show_ascii = false,
    }, 1, root.size)
    helpers.eq(lower.hex_start, 0)
    helpers.eq(lower.width, 17)
    helpers.eq(lower.ascii_start, 19)
    helpers.eq(layout.row(root, 0, lower), '00ff0020 7e7f80ff')
    helpers.eq(layout.cell(lower, 0, 0, 'ascii'), nil)
    helpers.eq(layout.hit(lower, 2, lower.ascii_start, 0, root.size), nil)
    local lower_offset = layout.compute({
      bytes_per_row = 8, uppercase_hex = false, show_ascii = false,
    }, 80, root.size)
    helpers.eq(string.sub(layout.row(root, 0x15, lower_offset), 1, lower_offset.offset_width), '000000a8')
  end),

  case('VIEW layout: empty document marker and non-data hit behavior', function()
    local root = document.empty()
    local computed = layout.compute({ bytes_per_row = 8, byte_group_size = 1 }, 80, root.size)
    helpers.eq(layout.row(root, 0, computed),
      '00000000  (empty)' .. string.rep(' ', 16) .. '  ' .. string.rep(' ', 8))
    helpers.eq(#layout.row(root, 0, computed), computed.width)
    helpers.eq(layout.hit(computed, 2, computed.hex_start, 0, root.size), nil)
    helpers.eq(layout.hit(computed, 2, computed.ascii_start, 0, root.size), nil)
    helpers.eq(layout.row(root, 1, computed), '')
  end),
}
