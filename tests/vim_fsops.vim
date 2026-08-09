set nocompatible
set nomore
set lines=60 columns=200

" Daemon-backed copy/move (the `fs-ops` capability).
"
" The assertion that carries this whole feature is deterministic rather than
" timing-dependent: Vim never runs a channel callback while Vimscript is
" executing, so with fs-ops on, `filereadable(dst)` immediately after
" OnPaste() returns is *guaranteed* false — the daemon cannot possibly have
" replied yet.  With g:simpletree_async_fs_ops = 0 the same call cannot return
" until the copy is finished, so it is guaranteed true.  One assertion, two
" opposite guaranteed values: that is the difference between "the copy blocks
" the editor" and "it does not".

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif

let s:root = tempname()
call mkdir(s:root .. '/dest', 'p')
call mkdir(s:root .. '/tree/nested', 'p')
call writefile(['leaf'], s:root .. '/tree/nested/leaf.txt')
call writefile(['one'], s:root .. '/one.txt')
call writefile(['two'], s:root .. '/two.txt')
call writefile(['occupied'], s:root .. '/dest/two.txt')
call mkdir(s:root .. '/chain', 'p')
call writefile(['inner'], s:root .. '/chain/inner.txt')

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_use_trash = 0
let g:simpletree_use_system_clipboard = 0
let g:simpletree_use_system_copy = 0
let g:simpletree_git_status = 0
let g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
execute 'set runtimepath^=' .. fnameescape(s:repo)
" 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
let g:simpletree_state_file = tempname() . '/state.json'
runtime plugin/simpletree.vim

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
endfunction

function! s:Vars() abort
  return getscriptinfo({'sid': s:Sid()})[0].variables
endfunction

function! s:TreeWin() abort
  for info in getwininfo()
    if getbufvar(info.bufnr, '&filetype') ==# 'simpletree'
      return info.winid
    endif
  endfor
  return 0
endfunction

function! s:SelectPath(path) abort
  call win_gotoid(s:TreeWin())
  let index = s:Vars().s_line_index
  for i in range(len(index))
    if get(index[i], 'path', '') ==# a:path
      call cursor(i + 1, 1)
      return
    endif
  endfor
  call assert_report('node is not in the tree: ' .. a:path)
endfunction

try
  execute 'SimpleTree ' .. fnameescape(s:root)
  sleep 600m

  call assert_true(index(simpletree#TestGetState().caps, 'fs-ops') >= 0,
        \ 'the daemon did not advertise fs-ops')

  " ------------------------------------------------ the copy does not block ---

  call s:SelectPath(s:root .. '/tree')
  call simpletree#OnCopy()
  call s:SelectPath(s:root .. '/dest')
  call simpletree#OnPaste()
  call assert_false(isdirectory(s:root .. '/dest/tree'),
        \ 'the copy ran inside Vim instead of being handed to the daemon')
  sleep 600m
  call assert_equal(['leaf'], readfile(s:root .. '/dest/tree/nested/leaf.txt'),
        \ 'the daemon copy did not reproduce the tree')

  " ----------------------------------------------- the fallback still works ---

  " With the capability switched off the same paste must still happen, just
  " synchronously: an installed but unusable escape hatch is worse than none.
  let g:simpletree_async_fs_ops = 0
  call s:SelectPath(s:root .. '/one.txt')
  call simpletree#OnCopy()
  call s:SelectPath(s:root .. '/dest')
  call simpletree#OnPaste()
  call assert_equal(['one'], readfile(s:root .. '/dest/one.txt'),
        \ 'the synchronous fallback did not copy')
  let g:simpletree_async_fs_ops = 1

  " ------------------------------------------------- overwrite stays staged ---

  " An overwriting copy must swap the old target aside and leave nothing behind;
  " a failure here would mean a paste can destroy a file it did not install.
  call simpletree#Refresh()
  sleep 600m
  call s:SelectPath(s:root .. '/two.txt')
  call simpletree#OnCopy()
  call s:SelectPath(s:root .. '/dest')
  call feedkeys("o\<CR>", 't')
  call simpletree#OnPaste()
  sleep 600m
  call assert_equal(['two'], readfile(s:root .. '/dest/two.txt'))
  call assert_equal([], glob(s:root .. '/dest/.simpletree-*', 0, 1),
        \ 'a staged or backup sibling survived a successful install')

  " ------------------------------------------------------------- cut / move ---

  call simpletree#Refresh()
  sleep 600m
  call s:SelectPath(s:root .. '/one.txt')
  call simpletree#OnCut()
  call s:SelectPath(s:root .. '/tree')
  call simpletree#OnPaste()
  call assert_true(filereadable(s:root .. '/one.txt'),
        \ 'the move ran inside Vim instead of being handed to the daemon')
  sleep 600m
  call assert_false(filereadable(s:root .. '/one.txt'), 'the move left its source behind')
  call assert_equal(['one'], readfile(s:root .. '/tree/one.txt'))
  call assert_equal(['', []], [s:Vars().s_clipboard.mode, s:Vars().s_clipboard.items],
        \ 'a fully applied cut must empty the clipboard')

  " --------------------------------------------- a refused op ends the chain ---

  " The daemon rejects a source that has vanished, and it must do so through a
  " real request: nothing here may set the clipboard by hand, because
  " getscriptinfo() hands back a *copy* of the script variables and a paste
  " driven that way would find an empty clipboard and quietly do nothing.
  "
  " The whole batch is planned before the first byte moves, so a job can be
  " approved and then have its source disappear underneath it — cutting a
  " directory together with a file inside it is exactly that, and it is a
  " two-key accident (`m` on both) rather than an exotic one.  The second job
  " must come back refused, and that refusal must resolve the job instead of
  " leaving the chain waiting for a reply that will never come.
  call simpletree#Refresh()
  sleep 600m
  call s:SelectPath(s:root .. '/chain')
  call simpletree#OnExpand()
  sleep 600m
  call s:SelectPath(s:root .. '/chain')
  call simpletree#OnMarkToggle()
  call s:SelectPath(s:root .. '/chain/inner.txt')
  call simpletree#OnMarkToggle()
  call simpletree#OnCut()
  call s:SelectPath(s:root .. '/dest')
  call simpletree#OnPaste()
  sleep 900m
  call assert_equal({}, s:Vars().s_fsop_cbs,
        \ 'a refused fs-op left its callback registered forever')
  call assert_equal(['inner'], readfile(s:root .. '/dest/chain/inner.txt'),
        \ 'the first job of the batch never completed')
  call assert_false(filereadable(s:root .. '/dest/inner.txt'),
        \ 'a refused move installed something at the destination anyway')
  " 被拒的那一项必须留在剪贴板里：用户还没有得到这次移动。
  call assert_equal(['cut', [s:root .. '/chain/inner.txt']],
        \ [s:Vars().s_clipboard.mode, s:Vars().s_clipboard.items],
        \ 'a refused cut did not stay on the clipboard')
  let s:msgs = execute('messages')
  call assert_true(stridx(s:msgs, 'failed to move: ' .. s:root .. '/chain/inner.txt') >= 0,
        \ 'the refusal was never reported: ' .. s:msgs)
  call assert_true(stridx(s:msgs, 'source does not exist') >= 0,
        \ "the daemon's reason for refusing never reached the user: " .. s:msgs)
catch
  call assert_report('unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

call delete(s:root, 'rf')
if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
