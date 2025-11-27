--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

--- Default options table for the extension.
-- All options can be overridden via document YAML front matter under
-- `extensions.regurgitate`.
-- @table options
-- @field group_by_language boolean Group code blocks by programming language (default: false)
-- @field show_code_inline boolean Keep code visible in original positions (default: true)
-- @field show_output_results boolean Include execution output in appendix (default: true)
-- @field appendix_title string Title for the appendix section (default: "Code Appendix")
-- @field appendix_level number Header level for appendix title, 1-6 (default: 1)
-- @field show_separator boolean Show horizontal rule before appendix (default: true)
-- @field number_blocks boolean Add "Code Block N" labels (default: false)
-- @field show_filename boolean Display filename labels when present (default: true)
-- @field collapsible boolean Make language sections collapsible in HTML (default: false)
-- @field debug boolean Enable verbose debug logging (default: false)
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

--- Storage for collected code blocks.
-- Each entry contains the code block, its results, language, and metadata.
-- @table code_blocks
-- @field code pandoc.CodeBlock The code block element
-- @field results table Array of result div elements
-- @field lang string Programming language identifier
-- @field is_cell boolean Whether this came from a Quarto cell
-- @field filename string|nil Optional filename attribute
local code_blocks = {}

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

--- Log a debug message.
-- Messages are only output when options.debug is true.
-- All messages are prefixed with "[REGURGITATE]" for easy filtering.
-- @param message string The message to log
-- @return nil
local function log(message)
  if options.debug then
    quarto.log.output("[REGURGITATE] " .. message)
  end
end

--- Validate and sanitize configuration options.
-- Ensures all options are within valid ranges and have sensible defaults.
-- Logs a warning if invalid values are corrected.
-- @return nil
local function validate_options()
  -- Ensure appendix_level is between 1 and 6
  if options.appendix_level < 1 or options.appendix_level > 6 then
    quarto.log.warning("[REGURGITATE] appendix-level must be 1-6, using 1")
    options.appendix_level = 1
  end
  
  -- Ensure appendix_title is not empty
  if not options.appendix_title or options.appendix_title == "" then
    options.appendix_title = "Code Appendix"
  end
  
  log("Options validated successfully")
end

--- Check if the current output format is HTML.
-- Used to conditionally apply HTML-specific features like collapsible sections.
-- @return boolean True if output format is HTML or HTML5
local function is_html_output()
  return quarto.doc.is_format("html") or quarto.doc.is_format("html5")
end

--------------------------------------------------------------------------------
-- Metadata Processing
--------------------------------------------------------------------------------

--- Process document metadata to extract extension options.
-- Reads configuration from `extensions.regurgitate` in the document's
-- YAML front matter and updates the options table accordingly.
-- @param meta pandoc.Meta The document metadata
-- @return pandoc.Meta The unmodified metadata (pass-through)
-- @usage
-- -- In document YAML:
-- -- extensions:
-- --   regurgitate:
-- --     group-by-language: true
-- --     appendix-title: "Source Code"
function Meta(meta)
  if meta.extensions and meta.extensions.regurgitate then
    local opts = meta.extensions.regurgitate
    
    -- Check debug flag FIRST so logging works for other options
    if opts['debug'] ~= nil then
      options.debug = opts['debug']
      if options.debug then
        quarto.log.output("[REGURGITATE] Debug mode enabled")
      end
    end
    
    log("=== Meta function called ===")
    log("Found regurgitate options")
    
    -- Boolean options
    local bool_opts = {
      'group-by-language', 'show-code-inline', 'show-output-results',
      'show-separator', 'number-blocks', 'show-filename', 'collapsible'
    }
    
    for _, opt_name in ipairs(bool_opts) do
      if opts[opt_name] ~= nil then
        local lua_name = opt_name:gsub("-", "_")
        options[lua_name] = opts[opt_name]
        log(opt_name .. ": " .. tostring(options[lua_name]))
      end
    end
    
    -- String options
    if opts['appendix-title'] then
      options.appendix_title = pandoc.utils.stringify(opts['appendix-title'])
      log("appendix-title: " .. options.appendix_title)
    end
    
    -- Numeric options
    if opts['appendix-level'] then
      options.appendix_level = tonumber(opts['appendix-level']) or 1
      log("appendix-level: " .. tostring(options.appendix_level))
    end
    
  else
    log("No regurgitate options found, using defaults")
  end
  
  validate_options()
  return meta
end

--------------------------------------------------------------------------------
-- Block Detection and Classification
--------------------------------------------------------------------------------

--- Check if a div element is a Quarto code cell.
-- Quarto wraps executable code blocks in divs with class "cell".
-- @param div pandoc.Div The div element to check
-- @return boolean True if the div is a Quarto cell
local function is_cell_div(div)
  if not div.classes then return false end
  
  for _, class in ipairs(div.classes) do
    if class == "cell" then
      return true
    end
  end
  return false
end

--- Check if a div element contains code output.
-- Quarto marks output divs with classes starting with "cell-output".
-- @param div pandoc.Div The div element to check
-- @return boolean True if the div is code output
local function is_code_output(div)
  if not div.classes then return false end
  
  for _, class in ipairs(div.classes) do
    if class:match("^cell%-output") then
      return true
    end
  end
  return false
end

--- Check if a block should be included in the appendix.
-- Blocks can be excluded by setting the "appendix" attribute to "false" or "no".
-- @param block pandoc.Block The block element to check
-- @return boolean True if the block should be included
-- @usage
-- -- In Quarto document:
-- -- ```{python}
-- -- #| appendix: false
-- -- # This code won't appear in appendix
-- -- ```
local function should_include_in_appendix(block)
  -- Check for explicit exclusion via attributes
  if block.attributes then
    local appendix_attr = block.attributes["appendix"]
    if appendix_attr == "false" or appendix_attr == "no" then
      log("Block excluded via appendix attribute")
      return false
    end
  end
  return true
end

--- Extract the filename attribute from a block if present.
-- @param block pandoc.Block The block to check for filename
-- @return string|nil The filename if present, nil otherwise
local function get_filename(block)
  if block.attributes and block.attributes["filename"] then
    return block.attributes["filename"]
  end
  return nil
end

--------------------------------------------------------------------------------
-- Code Block Extraction
--------------------------------------------------------------------------------

--- Extract code blocks and their results from a Quarto cell div.
-- Parses the cell structure to find code blocks (marked with "cell-code" class)
-- and their associated output divs.
-- @param div pandoc.Div The Quarto cell div to process
-- @return table Array of {code, results, filename} entries
-- @return string The detected programming language
local function extract_cell_contents(div)
  local code_and_results = {}
  local lang = "text"
  local last_code_index = nil
  
  -- Check cell-level appendix attribute
  if not should_include_in_appendix(div) then
    return code_and_results, lang
  end
  
  for _, block in ipairs(div.content) do
    if block.tag == "CodeBlock" then
      -- Check if this is the main code block (has cell-code class)
      local is_main_code = false
      for _, class in ipairs(block.classes) do
        if class == "cell-code" then
          is_main_code = true
          -- Get the language (first class that's not cell-code)
          for _, c in ipairs(block.classes) do
            if c ~= "cell-code" then
              lang = c
              break
            end
          end
          break
        end
      end
      
      if is_main_code and should_include_in_appendix(block) then
        -- Add this code block with an empty results list
        table.insert(code_and_results, {
          code = block,
          results = {},
          filename = get_filename(block) or get_filename(div)
        })
        last_code_index = #code_and_results
      end
    elseif block.tag == "Div" and is_code_output(block) then
      -- Attach result to the most recent code block
      if last_code_index then
        table.insert(code_and_results[last_code_index].results, block)
      end
    end
  end
  
  return code_and_results, lang
end

--- Collect all code blocks from document blocks.
-- Iterates through document blocks, identifying Quarto cells and standalone
-- code blocks, and adds them to the global code_blocks table.
-- @param blocks table Array of pandoc.Block elements
-- @return nil
local function collect_blocks(blocks)
  log("=== collect_blocks called with " .. #blocks .. " blocks ===")
  
  for i, block in ipairs(blocks) do
    log("Block " .. i .. ": type=" .. block.tag)
    
    if block.tag == "Div" and is_cell_div(block) then
      log("  -> Found a Quarto cell")
      -- This is a Quarto cell, extract code and results
      local code_and_results, lang = extract_cell_contents(block)
      
      if code_and_results and #code_and_results > 0 then
        log("  -> Extracted " .. #code_and_results .. " code block(s) with language: " .. lang)
        
        -- Add each code block from the cell separately with its paired results
        -- Using 'j' to avoid shadowing outer 'i'
        for j, pair in ipairs(code_and_results) do
          log("  -> Code block " .. j .. " has " .. #pair.results .. " result(s)")
          local code_entry = {
            code = pair.code,
            results = pair.results,
            lang = lang,
            is_cell = true,
            filename = pair.filename
          }
          table.insert(code_blocks, code_entry)
          log("  -> Added code block " .. j .. " to code_blocks (total now: " .. #code_blocks .. ")")
        end
      else
        log("  -> No code found in cell (or excluded)")
      end
      
    elseif block.tag == "CodeBlock" then
      log("  -> Found a standalone CodeBlock")
      
      -- Check if should be included
      if not should_include_in_appendix(block) then
        log("  -> CodeBlock excluded via attribute")
      elseif block.classes and #block.classes > 0 then
        log("  -> CodeBlock has " .. #block.classes .. " classes")
        log("  -> First class: " .. (block.classes[1] or "nil"))
        -- Only collect if it has language classes (not a result block)
        local code_entry = {
          code = block,
          results = {},
          lang = block.classes[1] or "text",
          is_cell = false,
          filename = get_filename(block)
        }
        table.insert(code_blocks, code_entry)
        log("  -> Added to code_blocks (total now: " .. #code_blocks .. ")")
      else
        log("  -> CodeBlock has no classes, skipping (likely a result)")
      end
    end
  end
  
  log("=== collect_blocks finished, collected " .. #code_blocks .. " code blocks ===")
end

--------------------------------------------------------------------------------
-- Display Helpers
--------------------------------------------------------------------------------

--- Create a display-only copy of a code block.
-- Returns the original block since code in the appendix won't be re-executed.
-- @param code_block pandoc.CodeBlock The code block to copy
-- @return pandoc.CodeBlock The code block (or empty block if input is invalid)
local function make_display_only_code(code_block)
  if not code_block or not code_block.text then
    log("WARNING: Invalid code block passed to make_display_only_code")
    return pandoc.CodeBlock("", pandoc.Attr("", {"text"}, {}))
  end
  
  -- Return the original code block - it preserves all attributes 
  -- including classes for syntax highlighting.
  -- Code in the appendix won't be re-executed by Quarto anyway.
  return code_block
end

--- Create a paragraph displaying the filename.
-- @param filename string The filename to display
-- @return pandoc.Para|nil A paragraph element, or nil if filename is nil
local function make_filename_label(filename)
  if not filename then return nil end
  
  return pandoc.Para({
    pandoc.Strong({pandoc.Str("File: ")}),
    pandoc.Code(filename)
  })
end

--- Create a numbered label for a code block.
-- @param index number The code block number
-- @param lang string|nil Optional language to include in label
-- @return pandoc.Para A paragraph element with the label
local function make_block_number_label(index, lang)
  local label_text = "Code Block " .. index
  if lang and lang ~= "text" then
    label_text = label_text .. " (" .. lang .. ")"
  end
  
  return pandoc.Para({
    pandoc.Strong({pandoc.Str(label_text)})
  })
end

--- Create an opening HTML tag for a collapsible section.
-- Only produces output for HTML format.
-- @param title string The summary text for the collapsible section
-- @return pandoc.RawBlock|nil HTML block or nil for non-HTML formats
local function make_collapsible_start(title)
  if not is_html_output() then return nil end
  
  return pandoc.RawBlock("html", 
    '<details class="code-appendix-section">\n<summary>' .. title .. '</summary>\n')
end

--- Create a closing HTML tag for a collapsible section.
-- Only produces output for HTML format.
-- @return pandoc.RawBlock|nil HTML block or nil for non-HTML formats
local function make_collapsible_end()
  if not is_html_output() then return nil end
  
  return pandoc.RawBlock("html", '</details>\n')
end

--------------------------------------------------------------------------------
-- Appendix Building
--------------------------------------------------------------------------------

--- Build appendix content grouped by programming language.
-- Creates a section for each language with code blocks sorted alphabetically
-- by language name.
-- @return table Array of pandoc.Block elements for the appendix
local function build_grouped_appendix()
  local appendix_blocks = {}
  local by_lang = {}
  local block_counter = 0
  
  -- Collect blocks by language
  for i, entry in ipairs(code_blocks) do
    local lang = entry.lang
    log("Processing code block " .. i .. " with language: " .. lang)
    if not by_lang[lang] then
      by_lang[lang] = {}
    end
    table.insert(by_lang[lang], {entry = entry, original_index = i})
  end
  
  -- Sort languages alphabetically for consistent output
  local langs = {}
  for lang, _ in pairs(by_lang) do
    table.insert(langs, lang)
  end
  table.sort(langs)
  log("Languages found: " .. table.concat(langs, ", "))
  
  -- Add blocks grouped by language
  for _, lang in ipairs(langs) do
    log("Adding section for language: " .. lang)
    local header_text = lang:gsub("^%l", string.upper)
    
    -- Add language header or collapsible start
    if options.collapsible and is_html_output() then
      local collapsible_start = make_collapsible_start(header_text)
      if collapsible_start then
        table.insert(appendix_blocks, collapsible_start)
      end
    else
      log("Creating header: " .. header_text)
      table.insert(appendix_blocks, pandoc.Header(options.appendix_level + 1, {pandoc.Str(header_text)}))
    end
    
    for _, item in ipairs(by_lang[lang]) do
      local entry = item.entry
      block_counter = block_counter + 1
      log("  Processing entry for " .. lang)
      
      -- Add block number if enabled
      if options.number_blocks then
        table.insert(appendix_blocks, make_block_number_label(block_counter, nil))
      end
      
      -- Add filename label if present and enabled
      if options.show_filename and entry.filename then
        local filename_label = make_filename_label(entry.filename)
        if filename_label then
          table.insert(appendix_blocks, filename_label)
        end
      end
      
      -- Add the code block
      local display_block = make_display_only_code(entry.code)
      table.insert(appendix_blocks, display_block)
      
      -- Add results if enabled
      if options.show_output_results then
        log("  Adding " .. #entry.results .. " result divs")
        for _, result in ipairs(entry.results) do
          table.insert(appendix_blocks, result)
        end
      end
    end
    
    -- Close collapsible section
    if options.collapsible and is_html_output() then
      local collapsible_end = make_collapsible_end()
      if collapsible_end then
        table.insert(appendix_blocks, collapsible_end)
      end
    end
  end
  
  return appendix_blocks
end

--- Build appendix content in sequential document order.
-- Preserves the original order of code blocks as they appear in the document.
-- @return table Array of pandoc.Block elements for the appendix
local function build_sequential_appendix()
  local appendix_blocks = {}
  
  for i, entry in ipairs(code_blocks) do
    log("Processing code block " .. i)
    
    -- Add block number if enabled
    if options.number_blocks then
      table.insert(appendix_blocks, make_block_number_label(i, entry.lang))
    end
    
    -- Add filename label if present and enabled
    if options.show_filename and entry.filename then
      local filename_label = make_filename_label(entry.filename)
      if filename_label then
        table.insert(appendix_blocks, filename_label)
      end
    end
    
    -- Add the code block
    local display_block = make_display_only_code(entry.code)
    table.insert(appendix_blocks, display_block)
    
    -- Add results if enabled
    if options.show_output_results then
      log("  Adding " .. #entry.results .. " result divs")
      for _, result in ipairs(entry.results) do
        table.insert(appendix_blocks, result)
      end
    end
  end
  
  return appendix_blocks
end

--------------------------------------------------------------------------------
-- Main Document Processing
--------------------------------------------------------------------------------

--- Process the complete Pandoc document.
-- This is the main entry point for the filter. It collects code blocks,
-- optionally removes inline code, builds the appendix, and appends it
-- to the document.
-- @param doc pandoc.Pandoc The complete document
-- @return pandoc.Pandoc The modified document with appendix
function Pandoc(doc)
  log("=== Pandoc function called ===")
  
  -- Handle empty documents gracefully
  if not doc.blocks or #doc.blocks == 0 then
    log("Empty document, returning unchanged")
    return doc
  end
  
  -- Collect all code blocks
  collect_blocks(doc.blocks)
  
  if #code_blocks == 0 then
    log("No code blocks collected, returning document unchanged")
    return doc
  end
  
  log("Collected " .. #code_blocks .. " code blocks total")
  
  -- Optionally remove inline code (if show_code_inline is false)
  if not options.show_code_inline then
    log("Removing inline code (show_code_inline is false)")
    local new_blocks = {}
    for _, block in ipairs(doc.blocks) do
      if block.tag == "Div" and is_cell_div(block) then
        log("  Skipping cell div")
      elseif block.tag == "CodeBlock" and block.classes and #block.classes > 0 then
        log("  Skipping standalone code block")
      else
        table.insert(new_blocks, block)
      end
    end
    doc.blocks = new_blocks
    log("Removed inline code, " .. #doc.blocks .. " blocks remain")
  else
    log("Keeping inline code (show_code_inline is true)")
  end
  
  -- Build the appendix
  log("=== Building appendix ===")
  local appendix_content = {}
  
  -- Add separator if enabled
  if options.show_separator then
    table.insert(appendix_content, pandoc.HorizontalRule())
  end
  
  -- Add the appendix header
  log("Creating appendix header: " .. options.appendix_title)
  local header_inlines = {}
  for word in options.appendix_title:gmatch("%S+") do
    if #header_inlines > 0 then
      table.insert(header_inlines, pandoc.Space())
    end
    table.insert(header_inlines, pandoc.Str(word))
  end
  table.insert(appendix_content, pandoc.Header(options.appendix_level, header_inlines))
  
  -- Build code blocks section
  local code_section
  if options.group_by_language then
    log("Building grouped appendix")
    code_section = build_grouped_appendix()
  else
    log("Building sequential appendix")
    code_section = build_sequential_appendix()
  end
  
  -- Add code section to appendix
  for _, block in ipairs(code_section) do
    table.insert(appendix_content, block)
  end
  
  -- Wrap everything in an appendix div for styling
  local appendix_div = pandoc.Div(
    appendix_content, 
    pandoc.Attr("code-appendix", {"appendix", "code-appendix"}, {})
  )
  
  -- Append to document
  log("Adding appendix div to document")
  table.insert(doc.blocks, appendix_div)
  
  log("=== Pandoc function complete ===")
  return doc
end

--------------------------------------------------------------------------------
-- Filter Registration
--------------------------------------------------------------------------------

--- Filter table for Pandoc.
-- Defines the order of filter execution: Meta first, then Pandoc.
-- @return table Array of filter tables
return {
  {Meta = Meta},
  {Pandoc = Pandoc}
}