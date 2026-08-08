set nocompatible
set nomore
set lines=60 columns=200

" A tree root that is a directory of checkouts (~/projects, ~/work, any non-git
" container).  resolve_repo_root() only ever walked upward, so such a root
" resolved to no repository at all and never showed a single mark; the failure
" was invisible.  Discovery now walks down too, which means one request answers
" with several git_status events — and the frontend has to merge them, because
" assigning s_git_status wholesale made the last repository erase the first.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif
if !executable('git')
  qa!
endif

let s:root = tempname()
call mkdir(s:root .. '/alpha', 'p')
call mkdir(s:root .. '/beta', 'p')
for s:name in ['alpha', 'beta']
  call system('git -C ' .. shellescape(s:root .. '/' .. s:name) .. ' init -q')
  call system('git -C ' .. shellescape(s:root .. '/' .. s:name)
        \ .. ' -c user.email=t@t -c user.name=t commit -q --allow-empty -m init')
  call writefile(['dirty'], s:root .. '/' .. s:name .. '/dirty.txt')
endfor

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_git_status = 1
let g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
execute 'set runtimepath^=' .. fnameescape(s:repo)
runtime plugin/simpletree.vim

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
endfunction

function! s:Vars() abort
  return getscriptinfo({'sid': s:Sid()})[0].variables
endfunction

function! s:WaitFor(Cond, ...) abort
  let l:limit = a:0 > 0 ? a:1 : 6000
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

try

enew
execute 'SimpleTree ' .. fnameescape(s:root)

" Both repositories must contribute.  Before discovery this set was empty; with
" discovery but without merging it held exactly one of the two.
call assert_true(s:WaitFor({-> has_key(s:Vars().s_git_status, s:root .. '/alpha/dirty.txt')}),
      \ 'the first repository under the root produced no marks')
call assert_true(s:WaitFor({-> has_key(s:Vars().s_git_status, s:root .. '/beta/dirty.txt')}),
      \ 'the second repository overwrote the first instead of merging')
call assert_equal('U', s:Vars().s_git_status[s:root .. '/alpha/dirty.txt'])
call assert_equal('U', s:Vars().s_git_status[s:root .. '/beta/dirty.txt'])

" Both repository roots are recorded, which is what lets :SimpleTreeHealth say
" why some marks are missing rather than naming whichever repo replied last.
call assert_equal(sort([s:root .. '/alpha', s:root .. '/beta']),
      \ sort(copy(s:Vars().s_git_repo_roots)))
let s:health = substitute(execute('call simpletree#Health()'), '\n', ' || ', 'g')
call assert_true(s:health =~# 'git status: \d\+ entries from 2 repos',
      \ 'health did not report the repository count: ' .. s:health)
call assert_false(s:health =~# 'git status: last query failed',
      \ 'a working multi-repo root was reported as a failure')

" A path belonging to no repository stays unmarked.
call writefile(['loose'], s:root .. '/loose.txt')
call assert_false(has_key(s:Vars().s_git_status, s:root .. '/loose.txt'))

" Re-rooting into one of them drops the other repository's entries entirely.
" `:SimpleTree` with the window open is a toggle, so close first — the same
" close-then-reopen path |simpletree-marks| pins for marks.
SimpleTreeClose
execute 'SimpleTree ' .. fnameescape(s:root .. '/alpha')
call assert_true(s:WaitFor({-> has_key(s:Vars().s_git_status, s:root .. '/alpha/dirty.txt')}),
      \ 're-rooting into a repository lost its own marks')
call assert_false(has_key(s:Vars().s_git_status, s:root .. '/beta/dirty.txt'),
      \ 'the old root''s repository survived a re-root')
call assert_equal([s:root .. '/alpha'], s:Vars().s_git_repo_roots)

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
