local W = require("config.terminal_widths")

return {
  "folke/snacks.nvim",
  opts = {
    terminal = {
      win = {
        position = "right",
        width = function(self)
          local id = vim.b[self.buf].snacks_terminal and vim.b[self.buf].snacks_terminal.id or 1
          return W.widths[id] or 0.3
        end,
        on_close = function(self)
          if self:win_valid() and self:buf_valid() then
            local id = vim.b[self.buf].snacks_terminal and vim.b[self.buf].snacks_terminal.id or 1
            W.widths[id] = vim.api.nvim_win_get_width(self.win)
          end
        end,
      },
    },
  },
}
