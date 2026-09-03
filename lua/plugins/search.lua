return {
  "ibhagwan/fzf-lua",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
    "nvim-treesitter/nvim-treesitter-context",
  },
  event = { "VeryLazy" },
  enabled = true,
  opts = {
    "default",
    winopts = {
      width = 0.9,
      preview = {
        layout = "flex",
        flip_columns = 150, -- 窗口宽度 >150列时用左右布局，≤150 列时自动切为上下布局。
        border = "noborder",
        vertical = "up:50%",
        horizontal = "right:50%",
        delay = 50,
      },
    },
    files = {
      path_shorten = 20, -- 搜索时目录最多展示多少个字符, 比如abcdefg/abcdefgh/main.cpp 只展示为 abc/abc/main.cpp
      rg_opts      = [[--color=never --hidden --files -g "!.git" -g "!.cache"]], -- fzf搜索文件时过滤某些目录
    },
    diagnostics = {
      split = "belowright new",
    },
    previewers = {
      bat = {
        cmd = false,
      },
    },
    grep = {
      RIPGREP_CONFIG_PATH = "~/.config/nvim/rg-config", -- 搜索时, 会读取该文件内的过滤规则, 过滤一些不需要的文件格式
    },
  },
  keys = {
    { "<leader>f/", "<cmd>FzfLua <CR>", desc = "FzfLua self" },
    { "<leader>ff", "<cmd>FzfLua files<CR>", desc = "files" },
    { "<leader>fb", "<cmd>FzfLua buffers<CR>", desc = "buffers" },
    { "<leader>fl", "<cmd>FzfLua live_grep_glob<CR>", desc = "live grep with glob" }, -- bcm_udf_t_init -- *.c !ifa !examples 表示包含c文件, 但是去掉路径含ifa、example的文件
    -- !ifa 表示去掉完整匹配ifa目录的文件
    -- !ifa* 表示去掉正则匹配ifa*的文件, 比如ifabc也可以被去掉
    { "<leader>fL", "<cmd>FzfLua live_grep_resume<CR>", desc = "live grep with resume" },
    { "<leader>fh", "<cmd>FzfLua help_tags<CR>", desc = "help" },
    { "<leader>fH", "<cmd>FzfLua highlights<CR>", desc = "highlights" },
    { "<leader>fm", "<cmd>FzfLua oldfiles<CR>", desc = "mru" }, -- mru: most recent used
    { "<leader>fc", "<cmd>FzfLua commands<CR>", desc = "commands" },
    { "<leader>fj", "<cmd>FzfLua jumps<CR>", desc = "jumplist" },
    { "<leader>fk", "<cmd>FzfLua keymaps<CR>", desc = "keymaps" },
    { "<leader>fq", "<cmd>FzfLua quickfix<CR>", desc = "quickfix" },
    { "<leader>fw", "<cmd>FzfLua grep_cword<CR>", desc = "cword" },
    { "<leader>fa", "<cmd>lua require('helper.asynctask').fzf_select()<CR>", desc = "asynctask" },

    { "<leader>d", "<cmd>FzfLua lsp_document_diagnostics<CR>", desc = "lsp_document_diagnostics" },
    { "<leader>fd", "<cmd>FzfLua lsp_definitions<CR>", desc = "lsp_definition" },
    { "<leader>fr", "<cmd>FzfLua lsp_references<CR>", desc = "lsp_references" },
    { "<leader>fi", "<cmd>FzfLua lsp_implementations<CR>", desc = "lsp_implementations" },
    { "<leader>fs", "<cmd>FzfLua lsp_document_symbols<CR>", desc = "lsp_document_symbols" },
    { "<leader>fS", "<cmd>FzfLua lsp_workspace_symbols<CR>", desc = "lsp_workspace_symbols" },

    { "<leader>fW", "<cmd>lua require('fzf-lua').grep_curbuf({ search = vim.fn.expand('<cword>') })<CR>", desc = "cword in curbuf" },

    { "<leader>hc", "<cmd>FzfLua command_history<CR>", desc = "find command history" },
    { "<leader>hs", "<cmd>FzfLua search_history<CR>", desc = "find search history" },
  },
}
