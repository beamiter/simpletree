set nocompatible
set nomore
set lines=60 columns=200

" :SimpleTreeHealth has to answer "why isn't this working".  Two facts it used
" to get wrong: it inferred "git status: active" from a capability bit even
" while every query failed, and it had nothing to say about a lib/ daemon that
" a plugin-manager update left unrebuilt.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif

" tempname() lives under /tmp, and the fixture below it holds no repository at
" any depth, so the daemon answers git_status with an error there.  It reports
" that itself now — discovery walks down as well as up — rather than passing
" git's own stderr through.
let s:root = tempname()
call mkdir(s:root, 'p')
call writefile(['top'], s:root .. '/top.txt')

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
execute 'set runtimepath^=' .. fnameescape(s:repo)
" 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
let g:simpletree_state_file = tempname() . '/state.json'
runtime plugin/simpletree.vim

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
endfunction

function! s:HealthText() abort
  return substitute(execute('call simpletree#Health()'), '\n', ' || ', 'g')
endfunction

let s:finished = 0

try

" A closed tree must not claim anything is running.
let s:text = s:HealthText()
call assert_true(s:text =~# 'session: closed', 'health did not report a closed session')
call assert_true(s:text =~# 'git status: not connected yet',
      \ 'health claimed a git status before the backend ever answered')
call assert_false(s:text =~# 'git status: active',
      \ 'health inferred an active git status from a capability bit')

" ---------------------------------------------------------- git status truth ---

enew
execute 'SimpleTree ' .. fnameescape(s:root)
sleep 1200m
let s:text = s:HealthText()
call assert_true(s:text =~# 'session: open', 'health did not report the open session')
call assert_false(s:text =~# 'git status: active',
      \ 'health still reports "active" for a root outside any repository')
call assert_true(s:text =~# 'git status: last query failed: \S',
      \ 'the daemon''s git_status error was dropped instead of reported: ' .. s:text)
call assert_true(s:text =~# 'not inside a git repository: ' .. escape(s:root, '/.'),
      \ 'the reported git failure lost the daemon''s own wording: ' .. s:text)

" The failing request must not leak its correlation entry either.
let s:vars = getscriptinfo({'sid': s:Sid()})[0].variables
call assert_equal(0, len(s:vars.s_bcbs), 'the git_status callback leaked')

SimpleTreeClose
call simpletree#Stop()
sleep 200m

" ------------------------------------------------------- stale binary detect ---

if has('unix') && executable('touch')
  let s:Fresh = function(printf('<SNR>%d_BackendFreshness', s:Sid()))

  let s:fake = tempname()
  call writefile(['#!/bin/sh'], s:fake)
  call system('touch -d "2000-01-01 00:00" ' .. shellescape(s:fake))
  call assert_equal(0, v:shell_error)
  let s:old = call(s:Fresh, [s:fake])
  call assert_true(s:old.known, 'the Rust sources beside the plugin were not found')
  call assert_true(s:old.stale,
        \ 'a daemon older than every Rust source was not reported as stale')
  call assert_true(s:old.newest !~# '^/', 'the stale report should name a repo-relative file')

  call system('touch -d "2099-01-01 00:00" ' .. shellescape(s:fake))
  call assert_equal(0, v:shell_error)
  let s:new = call(s:Fresh, [s:fake])
  call assert_true(s:new.known)
  call assert_false(s:new.stale, 'a daemon newer than every Rust source was called stale')

  " A path that does not exist cannot be compared, and must not be guessed at.
  let s:unknown = call(s:Fresh, [s:fake .. '-missing'])
  call assert_false(s:unknown.known)
  call assert_false(s:unknown.stale)

  call delete(s:fake)
endif

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
  call writefile(v:errors, '/tmp/simpletree-vim-health-errors')
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
