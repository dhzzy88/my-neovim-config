" 编码
set encoding=utf-8
set fileencodings=utf-8,gb2312,gbk,gb18030,latin1
set fileformat=unix
set fileformats=unix,dos
 
" 缩进与格式
filetype indent on
set autoindent
set smarttab
set cindent
set shiftwidth=4
set tabstop=4
set expandtab
set softtabstop=4
set backspace=eol,start,indent
 
" 搜索
set hlsearch
set incsearch
set ignorecase
set smartcase 

set showtabline=2

" 在jumplist中切到下一个点或者上一个点, C表示CTRL
nnoremap <C-n> <C-i>
nnoremap <C-p> <C-o>


" 按*键可搜索当前单词; 不映射的话会自动跳到下一个单词
noremap * :let @/ = "\\<<C-r><C-w>\\>"<cr>:set hlsearch<cr>

" yw 复制当前单词; dw删除当前单词
nnoremap yw yiw
nnoremap dw diw
nnoremap yl ^v$y

if &diff
    colorscheme evening 
endif
