return {
  {
    -- "yintao1995/codetour.nvim",
    dir = vim.fn.isdirectory(vim.fn.expand("~/projects/codetour.nvim")) == 1
        and vim.fn.expand("~/projects/codetour.nvim")
        or nil,
    url = "https://github.com/yintao1995/codetour.nvim",
    -- name = "codetour.nvim",

    cmd = {
      "CodeTourStart",
      "CodeTourEnd",
      "CodeTourNew",
      "CodeTourAddStep",
      "CodeTourOpenDir",
      "CodeTourResume",
    },
    keys = {
      { "<leader>tf", "<cmd>CodeTourStart<cr>", desc = "CodeTour find" },
      { "<leader>ce", "<cmd>CodeTourEnd<cr>", desc = "CodeTour: end" },
      { "<leader>tc", "<cmd>CodeTourNew<cr>", desc = "CodeTour: create a new tour" },
      { "<leader>ta", function()
          local depth = vim.v.count > 0 and vim.v.count or 1
          vim.cmd("CodeTourAddStep " .. depth)
        end, desc = "CodeTour: add step (count=depth 1-based, e.g. 2<leader>ta)" },
      { "<leader>ta", function()
          local depth = vim.v.count > 0 and vim.v.count or 1
          -- 退出 visual 让 '< '> 标记更新到本次选区
          local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
          vim.api.nvim_feedkeys(esc, "x", false)
          local s = vim.fn.line("'<")
          local e = vim.fn.line("'>")
          vim.cmd(string.format("%d,%dCodeTourAddStep %d", s, e, depth))
        end, mode = "x", desc = "CodeTour: add range step (count=depth)" },
      { "<leader>td", "<cmd>CodeTourOpenDir<cr>", desc = "CodeTour: open tours dir" },
      { "<leader>tR", "<cmd>CodeTourResume<cr>", desc = "CodeTour: resume tour for recording" },
    },
    config = function()
      require("codetour").setup({
        -- 跨设备同步推荐改成云盘路径，例如：
        -- tours_dir = vim.fn.expand("~/Dropbox/codetour-tours"),
        -- ~/.local/share/nvim/codetour/tours
      })
    end,
  },
}
