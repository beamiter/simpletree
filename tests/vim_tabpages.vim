set nocompatible
set nomore

" win_id2win() only searches the current tabpage, so a single global window id
" cannot describe a tree that may be shown in more than one tab.  These tests
" pin the three symptoms that fell out of that: a second tab opening a second
" tree, toggling from the first tab opening a third, and closing one tab
" tearing down the tree that is still live in another.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/tests/fake_tree_daemon.py'
let s:root = tempname()
call mkdir(s:root .. '/folder', 'p')
call writefile(['top'], s:root .. '/top.txt')
call writefile(['child'], s:root .. '/folder/child.txt')

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
execute 'set runtimepath^=' .. fnameescape(s:repo)
" 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
let g:simpletree_state_file = tempname() . '/state.json'
runtime plugin/simpletree.vim

function! s:Vars() abort
  let l:script = getscriptinfo({'name': 'autoload/simpletree.vim'})[0]
  return getscriptinfo({'sid': l:script.sid})[0].variables
endfunction

function! s:TreeWins(...) abort
  let l:tabnr = a:0 > 0 ? a:1 : 0
  let l:res = []
  for l:info in getwininfo()
    if getbufvar(l:info.bufnr, '&filetype') !=# 'simpletree'
      continue
    endif
    if l:tabnr > 0 && l:info.tabnr != l:tabnr
      continue
    endif
    call add(l:res, l:info)
  endfor
  return l:res
endfunction

let s:finished = 0

try

enew
execute 'SimpleTree ' .. fnameescape(s:root)
sleep 200m
call assert_equal(1, len(s:TreeWins(1)), 'tab 1 must hold exactly one tree')
let s:root_after_open = simpletree#GetRoot()

" A fresh tab has no tree until asked, and asking must not disturb tab 1.
tabnew
call assert_equal(0, len(s:TreeWins(2)), 'a fresh tab must start without a tree')
SimpleTree
sleep 200m
call assert_equal(1, len(s:TreeWins(2)), 'toggling in a new tab must open a tree there')
call assert_equal(1, len(s:TreeWins(1)), 'opening in tab 2 must not add a window to tab 1')
call assert_equal(s:root_after_open, simpletree#GetRoot(),
      \ 'joining an open session from a new tab must not re-root the tree')

" Toggling back in tab 1 must close tab 1's tree, not open a third one.
tabnext 1
SimpleTree
sleep 100m
call assert_equal(0, len(s:TreeWins(1)), 'toggle in tab 1 opened another tree instead of closing')
call assert_equal(1, len(s:TreeWins(2)), 'closing tab 1s tree closed tab 2s as well')
call assert_true(s:Vars().s_open, 'closing one tabs window ended the whole session')

" Reopen in tab 1, then drop tab 1 entirely: tab 2 must survive intact.
SimpleTree
sleep 200m
call assert_equal(1, len(s:TreeWins(1)))
tabnext 2
tabclose 1
sleep 100m
call assert_equal(1, len(s:TreeWins()), 'exactly one tree must survive the tab close')
call assert_true(s:Vars().s_open, 'closing an orphan tab tore down the live session')
call assert_equal(s:root_after_open, simpletree#GetRoot(),
      \ 'closing an orphan tab lost the tree root')

" ...and the survivor is still the tree the plugin talks to: toggling closes it
" rather than stacking a fresh one next to it.
SimpleTree
sleep 100m
call assert_equal(0, len(s:TreeWins()), 'the surviving tree stopped responding to toggle')
call assert_false(s:Vars().s_open, 'the last window closing did not end the session')

SimpleTree
sleep 200m
call assert_equal(1, len(s:TreeWins()), 'the tree could not be reopened after a full close')

let s:finished = 1

catch
  call add(v:errors, 'unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

if !s:finished
  call add(v:errors, 'the test body did not run to completion')
endif

SimpleTreeClose
call simpletree#Stop()
call delete(s:root, 'rf')
if len(v:errors) > 0
  call writefile(v:errors, '/tmp/simpletree-vim-tabpage-errors')
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
