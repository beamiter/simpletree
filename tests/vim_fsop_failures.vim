set nocompatible
set nomore
set lines=60 columns=200

" 守护进程搬运的三条失败出口。
"
" The happy path and a plain refusal are covered by tests/vim_fsops.vim against
" the real daemon.  What is left are the exits a healthy daemon on a healthy
" filesystem never takes, and that no fixture built inside Vim can reach:
"
"   1. the backend answers an `fs_op` with a protocol-level `error` rather than
"      an `fs_op_done` — it does that when a request is refused before it is
"      ever dispatched, e.g. at the active-request limit,
"   2. the backend dies with a transfer still outstanding,
"   3. a transfer fails *after* the old target has been displaced, so the reply
"      carries `installed: false` together with a non-empty `backup`.
"
" 1 and 2 are the same failure to the user if the frontend gets them wrong: the
" paste hangs forever on one item, with the clipboard, the marks and the render
" all stuck mid-state and not a word on screen.  3 is worse — the user's own
" file has been renamed to a dotted sibling that `g:simpletree_hide_dotfiles`
" then hides, and the only thing that names it is the message.
"
" tests/fsop_proxy.py sits in front of the real daemon and fakes exactly these
" three, selected by the source's filename, so one daemon serves the whole run.
"
" 跑法：vim -Nu NONE -n -i NONE -es -S tests/vim_fsop_failures.vim

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif

let s:root = tempname()
call mkdir(s:root .. '/dest', 'p')
call mkdir(s:root .. '/dest2', 'p')
call writefile(['refused'], s:root .. '/a-refuse.txt')
call writefile(['plain'], s:root .. '/b-plain.txt')
call writefile(['orphan'], s:root .. '/c-orphan.txt')
call writefile(['crash'], s:root .. '/d-crash.txt')
call writefile(['tail'], s:root .. '/e-tail.txt')

let $SIMPLETREE_PROXY_TARGET = s:daemon
let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:repo .. '/tests/fsop_proxy.py'
let g:simpletree_use_trash = 0
let g:simpletree_use_system_clipboard = 0
let g:simpletree_use_system_copy = 0
let g:simpletree_git_status = 0
let g:simpletree_use_nerdfont = 0
let g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
let g:simpletree_state_file = tempname() .. '/state.json'
execute 'set runtimepath^=' .. fnameescape(s:repo)
runtime plugin/simpletree.vim

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
endfunction

function! s:Vars() abort
  return getscriptinfo({'sid': s:Sid()})[0].variables
endfunction

function! s:TreeWin() abort
  for l:info in getwininfo()
    if getbufvar(l:info.bufnr, '&filetype') ==# 'simpletree'
      return l:info.winid
    endif
  endfor
  return 0
endfunction

function! s:WaitFor(Cond, ...) abort
  let l:limit = a:0 > 0 ? a:1 : 8000
  let l:waited = 0
  while l:waited < l:limit
    if a:Cond()
      return 1
    endif
    sleep 100m
    let l:waited += 100
  endwhile
  return a:Cond()
endfunction

function! s:SelectPath(path) abort
  call win_gotoid(s:TreeWin())
  let l:index = s:Vars().s_line_index
  for l:i in range(len(l:index))
    if get(l:index[l:i], 'path', '') ==# a:path
      call cursor(l:i + 1, 1)
      return
    endif
  endfor
  call assert_report('node is not in the tree: ' .. a:path)
endfunction

" 一次粘贴结束的判据只有一个：没有回调还挂在那里。挂着就是"卡住了"。
function! s:Settled() abort
  return empty(s:Vars().s_fsop_cbs)
endfunction

let s:finished = 0
try

execute 'SimpleTree ' .. fnameescape(s:root)
call assert_true(s:WaitFor({-> len(s:Vars().s_line_index) > 5}), 'the tree never listed its root')
call assert_true(index(simpletree#TestGetState().caps, 'fs-ops') >= 0,
      \ 'the proxied daemon did not advertise fs-ops')

" ------------------------------------- an `error` reply resolves the job ---

" 批次里第一项被拒。如果那条 error 没有结束这一项，第二项永远发不出去——
" 所以 b-plain.txt 落没落地，就是"链断没断"的判据。
messages clear
call s:SelectPath(s:root .. '/a-refuse.txt')
call simpletree#OnMarkToggle()
call s:SelectPath(s:root .. '/b-plain.txt')
call simpletree#OnMarkToggle()
call simpletree#OnCopy()
call s:SelectPath(s:root .. '/dest')
call simpletree#OnPaste()
call assert_true(s:WaitFor(function('s:Settled')),
      \ 'a refused fs-op left its callback registered forever')
call assert_equal(['plain'], readfile(s:root .. '/dest/b-plain.txt'),
      \ 'the refusal stalled the batch: the next item was never sent')
call assert_false(filereadable(s:root .. '/dest/a-refuse.txt'),
      \ 'a refused copy installed something at the destination anyway')
let s:msgs = execute('messages')
call assert_true(stridx(s:msgs, 'failed to copy: ' .. s:root .. '/a-refuse.txt') >= 0,
      \ 'the refusal was never reported: ' .. s:msgs)
call assert_true(stridx(s:msgs, 'backend refused the transfer') >= 0,
      \ "the backend's reason never reached the user: " .. s:msgs)

" ---------------------------- a failed install still names its backup ---

" installed:false 带着 backup：旧目标已经被挪到一个点开头的兄弟名字下，还原
" 也失败了。默认 g:simpletree_hide_dotfiles 让它在树里根本看不见,这条路径是
" 用户找回自己文件的唯一线索。
messages clear
call s:SelectPath(s:root .. '/c-orphan.txt')
call simpletree#OnCopy()
call s:SelectPath(s:root .. '/dest')
call simpletree#OnPaste()
call assert_true(s:WaitFor(function('s:Settled')),
      \ 'a failed fs-op left its callback registered forever')
let s:msgs = execute('messages')
call assert_true(stridx(s:msgs, s:root .. '/dest/c-orphan.txt.simpletree-backup-proxy') >= 0,
      \ 'the displaced original was left unnamed: ' .. s:msgs)
call assert_true(stridx(s:msgs, 'failed to copy: ' .. s:root .. '/c-orphan.txt') >= 0,
      \ 'the failure itself was not reported: ' .. s:msgs)

" ------------------------------ a backend that dies mid-batch fails the item ---

" 守护进程带着一项未答复的搬运消失。那一项必须以失败结束，批次里剩下的必须
" 继续（此时没有后端，走 Vim 内的同步回退），而不是整条链停在半路。
messages clear
call s:SelectPath(s:root .. '/d-crash.txt')
call simpletree#OnMarkToggle()
call s:SelectPath(s:root .. '/e-tail.txt')
call simpletree#OnMarkToggle()
call simpletree#OnCopy()
call s:SelectPath(s:root .. '/dest2')
call simpletree#OnPaste()
call assert_true(s:WaitFor(function('s:Settled')),
      \ 'a backend that died mid-batch left its callback registered forever')
call assert_equal(['tail'], readfile(s:root .. '/dest2/e-tail.txt'),
      \ 'the batch stopped at the dead backend instead of finishing the rest')
call assert_false(filereadable(s:root .. '/dest2/d-crash.txt'),
      \ 'the item the backend never answered was reported as installed')
let s:msgs = execute('messages')
call assert_true(stridx(s:msgs, 'failed to copy: ' .. s:root .. '/d-crash.txt') >= 0,
      \ 'the unanswered transfer was not reported as failed: ' .. s:msgs)
call assert_true(stridx(s:msgs, 'did not finish') >= 0,
      \ 'the reason the transfer failed was not reported: ' .. s:msgs)

let s:finished = 1

catch
  call add(v:errors, 'unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

if !s:finished
  call add(v:errors, 'the test body did not run to completion')
endif

let g:simpletree_persist_state = 0
silent! SimpleTreeClose
call simpletree#Stop()
call delete(s:root, 'rf')
if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
