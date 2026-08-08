set nocompatible
set nomore
set lines=60 columns=200

" :SimpleTreeSearch is the only thing in the plugin that writes the quickfix
" list, and two of them used to race: both callback sets stayed registered, so
" whichever walk finished last replaced the results the user was already
" reading and re-opened the window under them.  The abandoned walk also kept one
" of the eight concurrent-scan permits.
"
" The fake daemon answers everything except `search`, which it ignores, so both
" replies here are injected through simpletree#DispatchLine() in an exact order.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:root = tempname()
call mkdir(s:root, 'p')
call writefile(['top'], s:root .. '/top.txt')

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:repo .. '/tests/fake_tree_daemon.py'
let g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
execute 'set runtimepath^=' .. fnameescape(s:repo)
" 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
let g:simpletree_state_file = tempname() . '/state.json'
runtime plugin/simpletree.vim

function! s:Vars() abort
  let l:sid = getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
  return getscriptinfo({'sid': l:sid})[0].variables
endfunction

function! s:Chunk(id, name) abort
  return json_encode({
        \ 'type': 'search_chunk',
        \ 'id': a:id,
        \ 'entries': [{'name': a:name, 'path': s:root .. '/' .. a:name, 'is_dir': v:false}],
        \ 'done': v:true,
        \ })
endfunction

let s:finished = 0

try

enew
execute 'SimpleTree ' .. fnameescape(s:root)
sleep 300m
call simpletree#TestSetCaps(['search'])

call simpletree#Search('alpha')
let s:first = s:Vars().s_search_id
call assert_true(s:first > 0, 'the first search did not register')
call assert_true(has_key(s:Vars().s_bcbs, s:first))

call simpletree#Search('beta')
let s:second = s:Vars().s_search_id
call assert_true(s:second > 0)
call assert_notequal(s:first, s:second)
call assert_false(has_key(s:Vars().s_bcbs, s:first),
      \ 'the superseded search kept its callbacks and its scan permit')

" The abandoned walk finishing seconds later must not touch quickfix.
call setqflist([], 'r', {'title': 'untouched', 'items': []})
call simpletree#DispatchLine(s:Chunk(s:first, 'stale.txt'))
call assert_equal('untouched', getqflist({'title': 1}).title,
      \ 'a superseded search replaced the results the user was reading')
call assert_equal(0, len(getqflist()))

" The newest one still lands, and clears the serialisation slot behind it.
call simpletree#DispatchLine(s:Chunk(s:second, 'fresh.txt'))
call assert_equal('SimpleTree search: beta', getqflist({'title': 1}).title)
call assert_equal(1, len(getqflist()))
call assert_equal(0, s:Vars().s_search_id, 'a completed search stayed registered')
cclose

" Closing the tree must invalidate a search that is still in flight.
call simpletree#Search('gamma')
let s:third = s:Vars().s_search_id
call assert_true(s:third > 0)
SimpleTreeClose
sleep 100m
call assert_equal(0, s:Vars().s_search_id, 'closing the tree left a search armed')
call setqflist([], 'r', {'title': 'after-close', 'items': []})
call simpletree#DispatchLine(s:Chunk(s:third, 'late.txt'))
call assert_equal('after-close', getqflist({'title': 1}).title,
      \ 'a search that outlived its session rewrote the quickfix list')

let s:finished = 1

catch
  call add(v:errors, 'unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

if !s:finished
  call add(v:errors, 'the test body did not run to completion')
endif

call simpletree#Stop()
call delete(s:root, 'rf')
if len(v:errors) > 0
  call writefile(v:errors, '/tmp/simpletree-vim-search-errors')
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
