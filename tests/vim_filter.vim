vim9script
# Daemon-backed tree filter (F).
#
# The defect this pins: DirHasFilterMatch() only ever walked s_cache, so the
# filter could not see anything the user had not manually expanded.  In a tree
# that was just opened that is the entire project — F + a real filename found
# nothing, which reads as a broken feature rather than a documented limit.
#
# The whole suite therefore filters for a name that lives *only* inside a
# directory that has never been expanded.  Under the old loaded-nodes filter
# that is guaranteed to render nothing.

set nocompatible
set nomore
set lines=60 columns=200

var repo = fnamemodify(expand('<sfile>:p:h'), ':h')
var daemon = repo .. '/target/debug/simpletree-daemon'
if !executable(daemon)
  daemon = repo .. '/lib/simpletree-daemon'
endif
if !executable(daemon)
  echoerr 'daemon binary not found; build with cargo build first'
  cquit
endif

g:simpletree_daemon_path = daemon
g:simpletree_persist_width = 0
g:simpletree_use_trash = 0
g:simpletree_git_status = 0
g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'

var base = tempname()
call mkdir(base .. '/deep/deeper', 'p')
call mkdir(base .. '/other', 'p')
call writefile(['x'], base .. '/deep/deeper/needle.txt')
call writefile(['x'], base .. '/other/haystack.txt')
call writefile(['x'], base .. '/top.txt')

exe 'set runtimepath^=' .. fnameescape(repo)
# 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
g:simpletree_state_file = tempname() .. '/state.json'
runtime plugin/simpletree.vim

def TreeWin(): number
  for w in getwininfo()
    if getbufvar(w.bufnr, '&filetype') ==# 'simpletree'
      return w.winid
    endif
  endfor
  return 0
enddef

def TreeText(): string
  var w = TreeWin()
  return w == 0 ? '' : join(getbufline(winbufnr(w), 1, '$'), "\n")
enddef

def WaitFor(Cond: func(): bool, limit: number = 4000): bool
  var waited = 0
  while waited < limit
    if Cond()
      return true
    endif
    sleep 50m
    waited += 50
  endwhile
  return Cond()
enddef

def Vars(): dict<any>
  var sid = getscriptinfo({name: 'autoload/simpletree.vim'})[0].sid
  return getscriptinfo({sid: sid})[0].variables
enddef

try
  exe 'SimpleTree ' .. fnameescape(base)
  assert_true(WaitFor(() => TreeText() =~# 'top\.txt'), 'the tree never listed its root')

  var caps = simpletree#TestGetState().caps
  assert_true(index(caps, 'search') >= 0, 'the daemon did not advertise search')

  # deep/ has never been expanded, so nothing under it is in s_cache.
  assert_true(TreeText() !~# 'deeper', 'the fixture directory was already expanded')

  # ------------------------------------------- a match below an unexpanded dir ---

  simpletree#TestSetFilter('needle')
  assert_true(WaitFor(() => TreeText() =~# 'needle\.txt'),
    'the filter could not see a match inside a directory that was never expanded')
  var text = TreeText()
  assert_true(text =~# 'deep', 'the path to the match was not shown')
  assert_true(text =~# 'deeper', 'the intermediate directory was not shown')
  assert_true(text !~# 'haystack', 'a non-matching file survived the filter')
  assert_true(text !~# 'top\.txt', 'a non-matching file survived the filter')

  # Forced expansion is a render-time decision only: clearing the filter must
  # restore exactly the expansion state the user had, not the one the filter
  # needed.
  assert_false(get(get(Vars().s_state, base .. '/deep', {}), 'expanded', false),
    'the filter wrote its forced expansion into the user state')

  simpletree#TestSetFilter('')
  assert_true(WaitFor(() => TreeText() =~# 'top\.txt'), 'clearing the filter did not restore the tree')
  assert_true(TreeText() !~# 'deeper', 'clearing the filter left a directory expanded')

  # ---------------------------------------------------- the fallback still works ---

  # 'loaded' is the historical behaviour and must stay reachable: it is the only
  # mode available against a backend without the search capability.
  g:simpletree_filter_mode = 'loaded'
  simpletree#TestSetFilter('needle')
  sleep 400m
  assert_true(TreeText() !~# 'needle\.txt',
    'the loaded-nodes mode is supposed to be blind to unexpanded directories')
  simpletree#TestSetFilter('')
  g:simpletree_filter_mode = 'auto'

  # ------------------------------------------------------ a superseded filter ---

  # Each keystroke of a retyped filter issues a new search; a chunk from the
  # previous query arriving late must not put its matches back on screen.
  simpletree#TestSetFilter('needle')
  simpletree#TestSetFilter('haystack')
  assert_true(WaitFor(() => TreeText() =~# 'haystack\.txt'), 'the second filter never resolved')
  sleep 300m
  assert_true(TreeText() !~# 'needle', 'a superseded filter search re-added its matches')
  simpletree#TestSetFilter('')

  # ------------------------------------------------------------- no matches ---

  simpletree#TestSetFilter('zzz-nothing-matches')
  sleep 500m
  assert_true(TreeText() !~# 'top\.txt', 'a filter with no matches still showed files')
  simpletree#TestSetFilter('')
  assert_true(WaitFor(() => TreeText() =~# 'top\.txt'))
catch
  assert_report('unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

call delete(base, 'rf')
if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
