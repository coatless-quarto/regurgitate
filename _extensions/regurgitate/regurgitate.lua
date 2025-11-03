local code_blocks = {}
local group_by_language = false
local show_code_inline = true
local show_output_results = true
local debug = false  -- Debug flag - off by default

-- Helper function for logging (only when debug is enabled)
local function log(message)
  if debug then
    quarto.log.output("[REGURGITATE] " .. message)
  end
end

-- Read metadata to check extension options
function Meta(meta)
  if meta.extensions and meta.extensions.regurgitate then
    local opts = meta.extensions.regurgitate
    
    -- Check debug flag FIRST so logging works for other options
    if opts['debug'] ~= nil then
      debug = opts['debug']
      if debug then
        quarto.log.output("[REGURGITATE] Debug mode enabled")
      end
    end
    
    log("=== Meta function called ===")
    log("Found regurgitate options")
    
    if opts['group-by-language'] ~= nil then
      group_by_language = opts['group-by-language']
      log("group-by-language: " .. tostring(group_by_language))
    end
    
    if opts['show-code-inline'] ~= nil then
      show_code_inline = opts['show-code-inline']
      log("show-code-inline: " .. tostring(show_code_inline))
    end
    
    if opts['show-output-results'] ~= nil then
      show_output_results = opts['show-output-results']
      log("show-output-results: " .. tostring(show_output_results))
    end
  else
    log("No regurgitate options found, using defaults")
  end
  return meta
end

-- Check if a div is a Quarto cell
local function is_cell_div(div)
  if not div.classes then return false end
  
  for _, class in ipairs(div.classes) do
    if class == "cell" then
      return true
    end
  end
  return false
end

-- Check if a div is code output
local function is_code_output(div)
  if not div.classes then return false end
  
  for _, class in ipairs(div.classes) do
    if class:match("^cell%-output") then
      return true
    end
  end
  return false
end

-- Extract code and results from a cell div
local function extract_cell_contents(div)
  local code_and_results = {}
  local lang = "text"
  local last_code_index = nil
  
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
      
      if is_main_code then
        -- Add this code block with an empty results list
        table.insert(code_and_results, {
          code = block,
          results = {}
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

-- Collect code blocks from document blocks
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
        for i, pair in ipairs(code_and_results) do
          log("  -> Code block " .. i .. " has " .. #pair.results .. " result(s)")
          local code_entry = {
            code = pair.code,
            results = pair.results,
            lang = lang,
            is_cell = true
          }
          table.insert(code_blocks, code_entry)
          log("  -> Added code block " .. i .. " to code_blocks (total now: " .. #code_blocks .. ")")
        end
      else
        log("  -> No code found in cell")
      end
      
    elseif block.tag == "CodeBlock" then
      log("  -> Found a standalone CodeBlock")
      -- Standalone code block
      if block.classes and #block.classes > 0 then
        log("  -> CodeBlock has " .. #block.classes .. " classes")
        log("  -> First class: " .. (block.classes[1] or "nil"))
        -- Only collect if it has language classes (not a result block)
        local code_entry = {
          code = block,
          results = {},
          lang = block.classes[1] or "text",
          is_cell = false
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

-- Create a non-executable copy of a code block
local function make_display_only_code(code_block)
  log("=== make_display_only_code called ===")
  
  -- Check what we received
  if not code_block then
    log("ERROR: code_block is nil!")
    return pandoc.CodeBlock("ERROR: nil code block", pandoc.Attr("", {"text"}, {}))
  end
  
  log("code_block type: " .. type(code_block))
  log("code_block tag: " .. (code_block.tag or "NO TAG"))
  
  if not code_block.text then
    log("ERROR: code_block.text is nil!")
    return pandoc.CodeBlock("ERROR: no text", pandoc.Attr("", {"text"}, {}))
  end
  
  log("code_block.text length: " .. #code_block.text)
  
  -- Log the classes
  if code_block.classes then
    log("code_block.classes exists, length: " .. #code_block.classes)
    for i, class in ipairs(code_block.classes) do
      log("  Class " .. i .. ": " .. class)
    end
  else
    log("code_block.classes is nil")
  end
  
  -- Return the original code block
  -- This preserves all attributes including classes for syntax highlighting
  -- Code in the appendix won't be re-executed by Quarto anyway
  log("Returning original code block (preserves all attributes)")
  return code_block
end

-- Process document in a single pass
function Pandoc(doc)
  log("=== Pandoc function called ===")
  
  -- First, collect all code blocks
  collect_blocks(doc.blocks)
  
  if #code_blocks == 0 then
    log("No code blocks collected, returning document unchanged")
    return doc
  end
  
  log("Collected " .. #code_blocks .. " code blocks total")
  
  -- Then, optionally remove inline code (if show_code_inline is false)
  if not show_code_inline then
    log("Removing inline code (show_code_inline is false)")
    local new_blocks = {}
    for _, block in ipairs(doc.blocks) do
      if block.tag == "Div" and is_cell_div(block) then
        -- Skip cell divs
        log("  Skipping cell div")
      elseif block.tag == "CodeBlock" and block.classes and #block.classes > 0 then
        -- Skip standalone code blocks
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
  local appendix_blocks = {}
  
  -- Add a header
  log("Creating Code Appendix header")
  table.insert(appendix_blocks, pandoc.Header(1, {pandoc.Str("Code"), pandoc.Space(), pandoc.Str("Appendix")}))
  
  if group_by_language then
    log("Grouping by language")
    -- Group by language
    local by_lang = {}
    
    -- Collect blocks by language
    for i, entry in ipairs(code_blocks) do
      local lang = entry.lang
      log("Processing code block " .. i .. " with language: " .. lang)
      if not by_lang[lang] then
        by_lang[lang] = {}
      end
      table.insert(by_lang[lang], entry)
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
      log("Creating header: " .. header_text)
      table.insert(appendix_blocks, pandoc.Header(2, {pandoc.Str(header_text)}))
      
      for j, entry in ipairs(by_lang[lang]) do
        log("  Processing entry " .. j .. " for " .. lang)
        -- Add a clean copy of the code block (non-executable)
        log("  Calling make_display_only_code")
        local display_block = make_display_only_code(entry.code)
        log("  Adding display block to appendix")
        table.insert(appendix_blocks, display_block)
        
        -- Add results if show_output_results is true
        if show_output_results then
          log("  Adding " .. #entry.results .. " result divs")
          for _, result in ipairs(entry.results) do
            table.insert(appendix_blocks, result)
          end
        else
          log("  Skipping results (show_output_results is false)")
        end
      end
    end
  else
    log("Adding blocks in sequential order")
    -- Add blocks in order
    for i, entry in ipairs(code_blocks) do
      log("Processing code block " .. i)
      -- Add a clean copy of the code block (non-executable)
      log("  Calling make_display_only_code")
      local display_block = make_display_only_code(entry.code)
      log("  Adding display block to appendix")
      table.insert(appendix_blocks, display_block)
      
      -- Add results if show_output_results is true
      if show_output_results then
        log("  Adding " .. #entry.results .. " result divs")
        for _, result in ipairs(entry.results) do
          table.insert(appendix_blocks, result)
        end
      else
        log("  Skipping results (show_output_results is false)")
      end
    end
  end
  
  -- Append to document
  log("Adding " .. #appendix_blocks .. " blocks to document")
  for i, block in ipairs(appendix_blocks) do
    log("  Appending block " .. i .. " (type: " .. block.tag .. ")")
    table.insert(doc.blocks, block)
  end
  
  log("=== Pandoc function complete ===")
  return doc
end

-- Return filters in correct order
return {
  {Meta = Meta},
  {Pandoc = Pandoc}
}