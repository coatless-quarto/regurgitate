--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

---@class RegurgitateOptions
---@field group_by_language boolean Group code blocks by programming language
---@field show_code_inline boolean Keep code visible in its original position
---@field show_output_results boolean Include execution output in the appendix
---@field appendix_title string Title for the appendix section
---@field appendix_level integer Header level for the appendix title, 1-6
---@field show_separator boolean Show a horizontal rule before the appendix
---@field number_blocks boolean Add "Code Block N" labels
---@field show_filename boolean Display filename labels when present
---@field collapsible boolean Make language sections collapsible in HTML
---@field debug boolean Enable verbose debug logging

---@class CodeEntry
---@field code pandoc.CodeBlock The code block element
---@field results pandoc.Div[] Output divs that follow the code in its cell
---@field lang string Programming language identifier
---@field is_cell boolean Whether this came from a Quarto cell
---@field filename string|nil Optional filename label

-- Quarto's custom node for a code block with a filename. The Lua stubs don't
-- define Quarto's custom nodes, so this lists the fields used here.
---@class DecoratedCodeBlock
---@field code_block pandoc.CodeBlock|nil The wrapped code block
---@field filename string|nil

-- Default options. All of them can be overridden in the document's YAML
-- front matter under `extensions.regurgitate`.
---@type RegurgitateOptions
local options = {
  -- Display options
  group_by_language = false,
  show_code_inline = true,
  show_output_results = true,

  -- Appendix customization
  appendix_title = "Code Appendix",
  appendix_level = 1,
  show_separator = true,

  -- Code block options
  number_blocks = false,
  show_filename = true,
  collapsible = false,

  -- Debug
  debug = false
}

-- YAML key and type of each option. The field name is the key with
-- underscores. `debug` comes first so the other options can be logged.
---@type {key: string, kind: "boolean"|"string"|"number"}[]
local option_specs = {
  {key = "debug", kind = "boolean"},
  {key = "group-by-language", kind = "boolean"},
  {key = "show-code-inline", kind = "boolean"},
  {key = "show-output-results", kind = "boolean"},
  {key = "show-separator", kind = "boolean"},
  {key = "number-blocks", kind = "boolean"},
  {key = "show-filename", kind = "boolean"},
  {key = "collapsible", kind = "boolean"},
  {key = "appendix-title", kind = "string"},
  {key = "appendix-level", kind = "number"}
}

-- Code blocks collected for the appendix, in document order
---@type CodeEntry[]
local code_blocks = {}

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

-- Log a debug message, prefixed with "[REGURGITATE]", when `debug` is on
---@param message string
local function log(message)
  if options.debug then
    quarto.log.output("[REGURGITATE] " .. message)
  end
end

--------------------------------------------------------------------------------
-- Metadata Processing
--------------------------------------------------------------------------------

-- Convert a metadata value to an option of the given kind. A string or number
-- option that is false, empty, or not a number gives nil, which keeps the
-- default.
---@param value any Raw metadata value
---@param kind "boolean"|"string"|"number"
---@return boolean|string|number|nil
local function read_option(value, kind)
  if kind == "boolean" then
    return value ~= false
  elseif not value then
    return nil
  end

  local text = pandoc.utils.stringify(value)
  if kind == "number" then
    return tonumber(text)
  end
  return text ~= "" and text or nil
end

-- Read the extension options from the document metadata, for example:
--
--   extensions:
--     regurgitate:
--       group-by-language: true
--       appendix-title: "Source Code"
---@param meta pandoc.Meta
---@return pandoc.Meta
local function read_options(meta)
  local extensions = meta.extensions
  local opts = type(extensions) == "table" and extensions.regurgitate
  if type(opts) ~= "table" then
    return meta
  end

  for _, spec in ipairs(option_specs) do
    local raw = opts[spec.key]
    if raw ~= nil then
      local value = read_option(raw, spec.kind)
      if value ~= nil then
        options[(spec.key:gsub("-", "_"))] = value
        log(spec.key .. ": " .. tostring(value))
      end
    end
  end

  if options.appendix_level < 1 or options.appendix_level > 6 then
    quarto.log.warning("[REGURGITATE] appendix-level must be 1-6, using 1")
    options.appendix_level = 1
  end
  return meta
end

--------------------------------------------------------------------------------
-- Block Detection and Classification
--------------------------------------------------------------------------------

-- Quarto wraps executable code and its output in a div with class "cell"
---@param div pandoc.Div
---@return boolean
local function is_cell_div(div)
  return div.classes:includes("cell")
end

-- Quarto marks output divs with classes starting with "cell-output"
---@param div pandoc.Div
---@return boolean
local function is_code_output(div)
  return div.classes:find_if(function(class)
    return class:match("^cell%-output") ~= nil
  end) ~= nil
end

-- Check if a cell or code block may go in the appendix. Setting the
-- "appendix" attribute to "false" or "no" excludes it:
--
--   ```{python}
--   #| appendix: false
--   # This code won't appear in appendix
--   ```
---@param block pandoc.Div|pandoc.CodeBlock
---@return boolean
local function should_include_in_appendix(block)
  local appendix_attr = block.attributes["appendix"]
  return appendix_attr ~= "false" and appendix_attr ~= "no"
end

--------------------------------------------------------------------------------
-- Code Block Collection
--------------------------------------------------------------------------------

-- The Quarto cell the walk is currently inside, if any
---@type {include: boolean, filename: string|nil}|nil
local current_cell = nil

-- The most recent cell code entry; cell outputs attach to it
---@type CodeEntry|nil
local last_entry = nil

-- Add a code block to `code_blocks` if it belongs in the appendix.
-- Cell code (marked with the "cell-code" class) is paired with the outputs
-- that follow it. Other code blocks need a language class; unclassed blocks
-- are usually results.
---@param block pandoc.CodeBlock
---@param filename? string Filename from the block's filename wrapper
---@return boolean collected
local function collect_code_block(block, filename)
  ---@type CodeEntry
  local entry
  if block.classes:includes("cell-code") then
    if not (current_cell and current_cell.include
      and should_include_in_appendix(block)) then
      return false
    end
    entry = {
      code = block,
      results = {},
      -- The language is the first class that isn't "cell-code"
      lang = block.classes:find_if(function(class)
        return class ~= "cell-code"
      end) or "text",
      is_cell = true,
      filename = filename or block.attributes["filename"] or current_cell.filename
    }
    last_entry = entry
  elseif #block.classes > 0 and should_include_in_appendix(block) then
    entry = {
      code = block,
      results = {},
      lang = block.classes[1],
      is_cell = false,
      filename = filename or block.attributes["filename"]
    }
  else
    return false
  end

  table.insert(code_blocks, entry)
  log("Collected " .. entry.lang .. " code block " .. #code_blocks
    .. (entry.filename and (" (" .. entry.filename .. ")") or ""))
  return true
end

-- Track Quarto cells and collect their outputs. The walk runs top-down, so a
-- cell is seen before the code and outputs inside it, wherever the cell sits
-- (callouts, tabsets, columns, ...).
---@param div pandoc.Div
---@return nil
---@return boolean|nil recurse False to skip the div's contents
local function collect_div(div)
  if is_cell_div(div) then
    current_cell = {
      include = should_include_in_appendix(div),
      filename = div.attributes["filename"]
    }
    last_entry = nil
  elseif is_code_output(div) then
    -- Attach the output to the most recent code block of this cell, and
    -- don't look for code blocks inside the output itself
    if last_entry then
      table.insert(last_entry.results, div)
    end
    return nil, false
  end
  return nil
end

-- Collect a code block that Quarto wrapped to show its filename. Quarto moves
-- a cell's filename option into this wrapper before user filters run, so the
-- filename can only be read here.
---@param node DecoratedCodeBlock
---@return pandoc.Blocks|nil
---@return boolean|nil recurse False to skip the wrapped code block
local function collect_decorated_code(node)
  local block = node.code_block
  if not block or block.t ~= "CodeBlock" then
    return nil
  end

  if collect_code_block(block, node.filename) and not options.show_code_inline then
    -- Remove the code together with its filename label
    return pandoc.Blocks({})
  end
  return nil, false
end

-- Collect a code block, removing it when show_code_inline is false
---@param block pandoc.CodeBlock
---@return pandoc.Blocks|nil
local function collect_code(block)
  if collect_code_block(block) and not options.show_code_inline then
    return pandoc.Blocks({})
  end
  return nil
end

--------------------------------------------------------------------------------
-- Appendix Building
--------------------------------------------------------------------------------

-- Add one entry to the appendix: its labels, its code, and its results
---@param blocks pandoc.Blocks Appendix blocks to extend
---@param entry CodeEntry
---@param number integer Position shown in the "Code Block N" label
---@param lang string|nil Language shown in the label
local function add_entry(blocks, entry, number, lang)
  if options.number_blocks then
    local label_text = "Code Block " .. number
    if lang and lang ~= "text" then
      label_text = label_text .. " (" .. lang .. ")"
    end
    blocks:insert(pandoc.Para({pandoc.Strong({pandoc.Str(label_text)})}))
  end

  if options.show_filename and entry.filename then
    blocks:insert(pandoc.Para({
      pandoc.Strong({pandoc.Str("File: ")}),
      pandoc.Code(entry.filename)
    }))
  end

  blocks:insert(entry.code)

  if options.show_output_results then
    blocks:extend(entry.results)
  end
end

-- Build the appendix grouped by language, in alphabetical order. Each
-- language gets a header, or a <details> section when collapsible is on.
---@return pandoc.Blocks
local function build_grouped_appendix()
  local appendix_blocks = pandoc.Blocks({})

  -- Collect blocks by language
  ---@type table<string, CodeEntry[]>
  local by_lang = {}
  ---@type string[]
  local langs = {}
  for _, entry in ipairs(code_blocks) do
    if not by_lang[entry.lang] then
      by_lang[entry.lang] = {}
      table.insert(langs, entry.lang)
    end
    table.insert(by_lang[entry.lang], entry)
  end
  table.sort(langs)

  local collapsible = options.collapsible and quarto.doc.is_format("html")
  local block_counter = 0
  for _, lang in ipairs(langs) do
    local header_text = (lang:gsub("^%l", string.upper))
    if collapsible then
      appendix_blocks:insert(pandoc.RawBlock("html",
        '<details class="code-appendix-section">\n<summary>' .. header_text .. '</summary>\n'))
    else
      appendix_blocks:insert(pandoc.Header(options.appendix_level + 1, {pandoc.Str(header_text)}))
    end

    for _, entry in ipairs(by_lang[lang]) do
      block_counter = block_counter + 1
      add_entry(appendix_blocks, entry, block_counter, nil)
    end

    if collapsible then
      appendix_blocks:insert(pandoc.RawBlock("html", '</details>\n'))
    end
  end

  return appendix_blocks
end

-- Build the appendix in document order
---@return pandoc.Blocks
local function build_sequential_appendix()
  local appendix_blocks = pandoc.Blocks({})
  for i, entry in ipairs(code_blocks) do
    add_entry(appendix_blocks, entry, i, entry.lang)
  end
  return appendix_blocks
end

--------------------------------------------------------------------------------
-- Main Document Processing
--------------------------------------------------------------------------------

-- Append the appendix of collected code blocks to the document
---@param doc pandoc.Pandoc
---@return pandoc.Pandoc
local function add_appendix(doc)
  if #code_blocks == 0 then
    log("No code blocks collected, returning document unchanged")
    return doc
  end
  log("Building appendix from " .. #code_blocks .. " code blocks")

  local appendix_content = pandoc.Blocks({})
  if options.show_separator then
    appendix_content:insert(pandoc.HorizontalRule())
  end

  -- Add the appendix header
  local header_inlines = pandoc.Inlines({})
  for word in options.appendix_title:gmatch("%S+") do
    if #header_inlines > 0 then
      header_inlines:insert(pandoc.Space())
    end
    header_inlines:insert(pandoc.Str(word))
  end
  appendix_content:insert(pandoc.Header(options.appendix_level, header_inlines))

  if options.group_by_language then
    appendix_content:extend(build_grouped_appendix())
  else
    appendix_content:extend(build_sequential_appendix())
  end

  -- Wrap everything in an appendix div for styling
  doc.blocks:insert(pandoc.Div(
    appendix_content,
    pandoc.Attr("code-appendix", {"appendix", "code-appendix"}, {})
  ))
  return doc
end

--------------------------------------------------------------------------------
-- Filter Registration
--------------------------------------------------------------------------------

-- Read the options, collect code blocks in a top-down walk, then append the
-- appendix
return {
  {Meta = read_options},
  {
    traverse = "topdown",
    Div = collect_div,
    DecoratedCodeBlock = collect_decorated_code,
    CodeBlock = collect_code
  },
  {Pandoc = add_appendix}
}
