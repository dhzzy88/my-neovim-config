return {
  "nvim-neo-tree/neo-tree.nvim",

  opts = {
    sources = { -- neo-tree窗口可以切换不同的显示面板
      "filesystem",
      "buffers",
      "git_status",
      "document_symbols",
    },
    source_selector = {
      winbar = true, -- 顶部显示 source 切换栏(filesystem/buffers/git/symbols)
      statusline = false,
      sources = { -- 必须在这里列出, winbar tab 才会出现 document_symbols
        { source = "filesystem" },
        { source = "buffers" },
        { source = "git_status" },
        { source = "document_symbols" },
      },
    },
    filesystem = {
      bind_to_cwd = true, -- 按leader+e打开neotree时切换工作目录过去
    },
  },
}
