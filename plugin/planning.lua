
-- plugin/planning.lua
if vim.g.loaded_planning then return end
vim.g.loaded_planning = 1

require("planning").setup()

