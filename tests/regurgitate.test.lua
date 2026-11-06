-- regurgitate tests. Run from the repo root: quarto pandoc lua path/to/qtest.lua
-- The fixture runs R code, so it needs R with rmarkdown.
local t = require("qtest")

--- The rendered appendix: everything from the appendix div on.
---@param html string
---@return string
local function appendix(html)
  local start = html:find('id="code-appendix"', 1, true)
  t.ok(start, "the page has a code appendix")
  return html:sub(start)
end

-- Regression: knitr splits a cell's code wherever output appears, and each
-- piece became its own appendix entry ("Code Block 1", "Code Block 2"). Joining
-- the pieces must stop at the end of the cell, so the next cell keeps its own
-- entry. (Jupyter keeps a cell's code in one block, and the filter doesn't
-- depend on the engine otherwise, so knitr alone covers it.)
t.test("knitr: each cell is one appendix entry, with its outputs after it", function()
  local r = t.render("knitr.qmd", "html")
  r:succeeded()
  local a = appendix(r.text)
  t.count(a, '<div class="sourceCode cell-code"', 2)
  t.in_order(a, { '<div class="sourceCode cell-code"', "[1] 1", "[1] 2",
    '<div class="sourceCode cell-code"', "[1] 3" })
end)
