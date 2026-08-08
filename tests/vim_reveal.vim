set nocompatible
set nomore

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/tests/fake_tree_daemon.py'
let s:root = tempname()
let s:outside = tempname()
call mkdir(s:root .. '/folder/deep space', 'p')
call mkdir(s:root .. '/other/nested', 'p')
call mkdir(s:outside, 'p')
call writefile(['top'], s:root .. '/top.txt')
call writefile(['target'], s:root .. '/folder/deep space/target file.txt')
call writefile(['second'], s:root .. '/other/nested/second.txt')
call writefile(['outside'], s:outside .. '/outside.txt')
let s:backslash_file = s:root .. '/literal\name.txt'
if has('unix')
  call writefile(['backslash'], s:backslash_file)
endif
let s:has_links = has('unix') && executable('ln')
if s:has_links
  call system('ln -s ' .. shellescape(s:root .. '/folder') .. ' '
        \ .. shellescape(s:root .. '/inside-link'))
  call assert_equal(0, v:shell_error)
  call system('ln -s ' .. shellescape(s:outside) .. ' '
        \ .. shellescape(s:root .. '/escape'))
  call assert_equal(0, v:shell_error)
  call system('ln -s ' .. shellescape(s:root .. '/folder') .. ' '
        \ .. shellescape(s:outside .. '/reenter'))
  call assert_equal(0, v:shell_error)
endif

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_use_system_clipboard = 0
execute 'set runtimepath^=' .. fnameescape(s:repo)
" 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
let g:simpletree_state_file = tempname() . '/state.json'
runtime plugin/simpletree.vim

function! s:TreeWin() abort
  for l:info in getwininfo()
    if getbufvar(l:info.bufnr, '&filetype') ==# 'simpletree'
      return l:info.winid
    endif
  endfor
  return 0
endfunction

function! s:Vars() abort
  let l:script = getscriptinfo({'name': 'autoload/simpletree.vim'})[0]
  return getscriptinfo({'sid': l:script.sid})[0].variables
endfunction

function! s:PathLine(path) abort
  let l:want = substitute(fnamemodify(a:path, ':p'), '/\+$', '', '')
  let l:index = s:Vars().s_line_index
  for l:i in range(len(l:index))
    let l:got = substitute(fnamemodify(get(l:index[l:i], 'path', ''), ':p'), '/\+$', '', '')
    if l:got ==# l:want
      return l:i + 1
    endif
  endfor
  return 0
endfunction

enew
execute 'SimpleTree ' .. fnameescape(s:root)
call assert_equal(2, exists(':SimpleTreeReveal'))

" The root scan publishes a partial cache without top.txt, then keeps the same
" request in flight for 1.1s. Reveal must attach to that request without
" cancelling/resending it; its final chunk arrives after all five 150ms
" fallback attempts and must still select the target.
for s:attempt in range(100)
  if has_key(s:Vars().s_cache, s:root) && get(s:Vars().s_loading, s:root, v:false)
    break
  endif
  sleep 10m
endfor
call assert_true(has_key(s:Vars().s_cache, s:root),
      \ 'root scan did not publish its first chunk')
call assert_true(get(s:Vars().s_loading, s:root, v:false),
      \ 'root scan completed before the partial-cache reveal')
call assert_equal(0, s:PathLine(s:root .. '/top.txt'),
      \ 'the first chunk unexpectedly contained the reveal target')
let s:root_request = get(s:Vars().s_pending, s:root, 0)
call assert_true(s:root_request > 0, 'partial root scan has no pending request')
call simpletree#OnRevealActive('top.txt')
let s:slow_token = s:Vars().s_reveal_generation
call assert_equal(s:slow_token, get(s:Vars().s_reveal_waiting, s:root, 0),
      \ 'reveal token was not attached to the pre-existing root scan')
call assert_equal(s:root_request, get(s:Vars().s_pending, s:root, 0),
      \ 'partial-cache reveal cancelled or resent the root scan')
sleep 1300m
call assert_equal('', s:Vars().s_reveal_target,
      \ 'slow root completion did not finish the current reveal')
call assert_equal(0, s:Vars().s_reveal_timer,
      \ 'slow root completion left the expired fallback timer registered')
call assert_equal(s:PathLine(s:root .. '/top.txt'), getcurpos(s:TreeWin())[1],
      \ 'slow pre-existing root scan lost the reveal after fallback expiry')

" Root, directory, root-relative paths and spaces are all explicit targets.
execute 'SimpleTreeReveal ' .. fnameescape(s:root)
call assert_equal(s:PathLine(s:root), getcurpos(s:TreeWin())[1])
execute 'SimpleTreeReveal folder'
sleep 300m
call assert_equal(s:PathLine(s:root .. '/folder'), getcurpos(s:TreeWin())[1])

" Relative paths follow the tree root even when the invoking split has an lcd.
execute 'lcd ' .. fnameescape(s:outside)
execute 'SimpleTreeReveal ' .. fnameescape('folder/deep space/target file.txt')
sleep 600m
call assert_equal(s:PathLine(s:root .. '/folder/deep space/target file.txt'),
      \ getcurpos(s:TreeWin())[1], 'relative reveal used :lcd instead of the tree root')

" Completion follows the same root-relative spelling and containment policy.
" Results are fnameescape()'d so a completed directory can continue through a
" space without changing the command's one-argument shape.
let s:completion = simpletree#CompleteReveal('folder/de', '', 0)
call assert_true(index(s:completion, fnameescape('folder/deep space/')) >= 0,
      \ 'relative completion followed :lcd instead of the tree root')
let s:command_completion = getcompletion('SimpleTreeReveal folder/de', 'cmdline')
call assert_true(index(s:command_completion, fnameescape('folder/deep space/')) >= 0,
      \ 'SimpleTreeReveal command did not use the root-relative completer')
let s:completion = simpletree#CompleteReveal('folder/deep\ space/tar', '', 0)
call assert_true(index(s:completion,
      \ fnameescape('folder/deep space/target file.txt')) >= 0,
      \ 'completion could not continue through an escaped space')
let s:absolute_completion = simpletree#CompleteReveal(s:root .. '/folder/de', '', 0)
call assert_true(index(s:absolute_completion,
      \ fnameescape(s:root .. '/folder/deep space/')) >= 0,
      \ 'absolute in-root completion lost a valid candidate')
let s:root_completion = simpletree#CompleteReveal(s:root .. '/', '', 0)
call assert_true(index(s:root_completion, fnameescape(s:root .. '/folder/')) >= 0,
      \ 'a trailing root separator completed only the root instead of its children')
call assert_equal([], simpletree#CompleteReveal(s:outside .. '/', '', 0),
      \ 'absolute completion enumerated outside the tree root')

" Exercise the actual customlist insertion and <q-args> decoding boundary,
" rather than only calling the completer as a function.
call feedkeys(":SimpleTreeReveal folder/de\<Tab>\<CR>", 'xt')
sleep 100m
call assert_equal(s:PathLine(s:root .. '/folder/deep space'),
      \ getcurpos(s:TreeWin())[1],
      \ 'command-line completion did not round-trip an escaped space')
if has('unix')
  let s:backslash_completion = simpletree#CompleteReveal('literal', '', 0)
  call assert_true(index(s:backslash_completion,
        \ fnameescape('literal\name.txt')) >= 0,
        \ 'completion lost a literal Unix backslash filename')
  call feedkeys(":SimpleTreeReveal literal\<Tab>\<CR>", 'xt')
  sleep 100m
  call assert_equal(s:PathLine(s:backslash_file), getcurpos(s:TreeWin())[1],
        \ 'completion/command decoding did not round-trip a literal backslash')
  execute 'SimpleTreeReveal ' .. fnameescape('literal\name.txt')
  call assert_equal(s:PathLine(s:backslash_file), getcurpos(s:TreeWin())[1],
        \ 'explicit fnameescape command double-decoded a literal backslash')
endif

if s:has_links
  call assert_equal([], simpletree#CompleteReveal('esc', '', 0),
        \ 'completion exposed an escaping symlink candidate')
  call assert_equal([], simpletree#CompleteReveal('escape/reenter/', '', 0),
        \ 'completion traversed a symlink that escaped before re-entering')
  call assert_true(index(simpletree#CompleteReveal('inside', '', 0),
        \ fnameescape('inside-link/')) >= 0,
        \ 'completion hid a safe in-root directory symlink')
  execute 'SimpleTreeReveal inside-link'
  sleep 100m
  call assert_equal(s:PathLine(s:root .. '/inside-link'), getcurpos(s:TreeWin())[1],
        \ 'an in-root symlink could not be revealed')
endif

" Failed validation is synchronous and observationally transparent.
sleep 300m
let s:before_state = deepcopy(s:Vars().s_state)
let s:before_cache = deepcopy(s:Vars().s_cache)
let s:before_pending = deepcopy(s:Vars().s_pending)
let s:before_loading = deepcopy(s:Vars().s_loading)
let s:before_waiting = deepcopy(s:Vars().s_reveal_waiting)
let s:before_generation = s:Vars().s_reveal_generation
let s:before_target = s:Vars().s_reveal_target
let s:before_epoch = simpletree#TestGetState().render_stats.epoch
let s:before_line = getcurpos(s:TreeWin())[1]
if s:has_links
  " The final path resolves back inside root, but its lexical escape ancestor
  " resolves outside and must reject the entire reveal transaction.
  let s:message = execute('SimpleTreeReveal escape/reenter/deep\ space/target\ file.txt')
  call assert_match('reveal target is outside the workspace root:', s:message)
  let s:message = execute('SimpleTreeReveal escape/outside.txt')
  call assert_match('reveal target is outside the workspace root:', s:message)
endif
let s:message = execute('SimpleTreeReveal folder/not-present.txt')
call assert_match('reveal target does not exist:', s:message)
let s:message = execute('SimpleTreeReveal ' .. fnameescape(s:outside .. '/outside.txt'))
call assert_match('reveal target is outside the workspace root:', s:message)
call assert_equal(s:before_state, s:Vars().s_state,
      \ 'failed reveal changed expanded-node state')
call assert_equal(s:before_cache, s:Vars().s_cache,
      \ 'failed reveal changed the directory cache')
call assert_equal(s:before_pending, s:Vars().s_pending,
      \ 'failed reveal changed pending requests')
call assert_equal(s:before_loading, s:Vars().s_loading,
      \ 'failed reveal changed loading state')
call assert_equal(s:before_waiting, s:Vars().s_reveal_waiting,
      \ 'failed reveal changed reveal wait tokens')
call assert_equal(s:before_generation, s:Vars().s_reveal_generation,
      \ 'failed reveal advanced the reveal generation')
call assert_equal(s:before_target, s:Vars().s_reveal_target,
      \ 'failed reveal changed the active reveal target')
call assert_equal(s:before_epoch, simpletree#TestGetState().render_stats.epoch,
      \ 'failed reveal invalidated the render cache')
call assert_equal(s:before_line, getcurpos(s:TreeWin())[1],
      \ 'failed reveal moved the selection')

" A second reveal supersedes the first. Invoking the old timer callback cannot
" clear or focus the newer target, even when its scan completes later.
call simpletree#OnRevealActive('folder/deep space/target file.txt')
let s:first_token = s:Vars().s_reveal_generation
call simpletree#OnRevealActive('other/nested/second.txt')
let s:second_token = s:Vars().s_reveal_generation
let s:session = s:Vars().s_session_generation
let s:script = getscriptinfo({'name': 'autoload/simpletree.vim'})[0]
call call(function(printf('<SNR>%d_RevealTimerCb', s:script.sid)),
      \ [999999, s:session, s:first_token])
call assert_equal(s:second_token, s:Vars().s_reveal_generation)
call assert_equal(s:root .. '/other/nested/second.txt', s:Vars().s_reveal_target,
      \ 'a stale reveal callback cleared the current target')
sleep 700m
call assert_equal(s:PathLine(s:root .. '/other/nested/second.txt'),
      \ getcurpos(s:TreeWin())[1], 'the newest reveal did not win')

SimpleTreeClose
call simpletree#Stop()
call delete(s:root, 'rf')
call delete(s:outside, 'rf')
if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
