set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
let mapleader = ','
let g:simpletree_persist_width = 0
let g:simpletree_page = 0
nnoremap <leader>e :let g:simpletree_user_mapping_ran = 1<CR>

execute 'set runtimepath^=' .. fnameescape(s:root)
runtime plugin/simpletree.vim

call assert_equal(1, g:simpletree_page, 'page size must be clamped away from zero')
call assert_match('simpletree_user_mapping_ran', maparg(',e', 'n'), 'user mapping was overwritten')
call assert_notequal('', maparg('<Plug>(simpletree-toggle)', 'n'), 'missing <Plug> mapping')
call assert_equal(2, exists(':SimpleTree'))
call assert_equal(2, exists(':SimpleTreeRefresh'))
call assert_equal(2, exists(':SimpleTreeReveal'))
call assert_equal(2, exists(':SimpleTreeHealth'))

" Calling this also compiles the autoload module in a clean, headless Vim.
silent call simpletree#Health()

if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
