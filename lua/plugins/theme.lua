return {
  {
    "folke/twilight.nvim",
    opts = {
      -- your configuration comes here
      -- or leave it empty to use the default settings
      -- refer to the configuration section below
    },
  },
  {
    "rebelot/kanagawa.nvim",
    opts = {},
  },
  {
    "Mofiqul/vscode.nvim",
    opts = {},
  },
  {
    "nvimdev/dashboard-nvim",
    event = "VimEnter",
    config = function()
      require("dashboard").setup({
        -- config
        mru = {
          limir = 5,
        },
      })
    end,
    dependencies = { { "nvim-tree/nvim-web-devicons" } },
  },
  {
    "nvim-mini/mini.cursorword",
    version = "*",
  },
}
