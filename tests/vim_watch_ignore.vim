vim9script
# Real notify + native daemon, driven through the Vim tree. A collapsed
# directory must not keep stale children after an inherited ignore edit.
set nocompatible
set nomore
set lines=60 columns=180

var repo = fnamemodify(expand('<sfile>:p:h'), ':h')
var daemon = repo .. '/target/debug/simpletree-daemon'
var base = resolve(tempname())
var project = base .. '/project'
var branch = project .. '/branch'
var deep = branch .. '/deep'
var sibling = project .. '/branch-other'
var leaf = deep .. '/hide-me.txt'
var other = sibling .. '/keep-me.txt'
var policy = branch .. '/.gitignore'

g:simpletree_daemon_path = daemon
g:simpletree_persist_width = 0
g:simpletree_persist_state = 0
g:simpletree_git_status = 0
g:simpletree_auto_refresh = 0
g:simpletree_git_ignore = 1
g:simpletree_use_watcher = 1
g:simpletree_bookmarks_file = base .. '/bookmarks'
execute 'set runtimepath^=' .. fnameescape(repo)
runtime plugin/simpletree.vim

def Vars(): dict<any>
  var sid = getscriptinfo({name: 'autoload/simpletree.vim'})[0].sid
  return getscriptinfo({sid: sid})[0].variables
enddef

def WaitFor(Cond: func(): bool): bool
  for _ in range(160)
    if Cond()
      return true
    endif
    sleep 50m
  endfor
  return Cond()
enddef

def Row(path: string): number
  var rows = Vars().s_line_index
  for i in range(len(rows))
    if get(rows[i], 'path', '') ==# path
      return i + 1
    endif
  endfor
  return 0
enddef

def Toggle(path: string)
  var row = Row(path)
  assert_true(row > 0, 'expected a visible row: ' .. path)
  if row > 0
    cursor(row, 1)
    simpletree#OnEnter()
  endif
enddef

try
  mkdir(deep, 'p')
  mkdir(sibling, 'p')
  writefile(['x'], leaf)
  writefile(['x'], other)
  system('git init -q ' .. shellescape(project))
  assert_equal(0, v:shell_error, 'git init failed')
  execute 'SimpleTree ' .. fnameescape(project)
  assert_true(WaitFor(() => Row(branch) > 0 && Row(sibling) > 0), 'root was not listed')
  Toggle(branch)
  Toggle(sibling)
  assert_true(WaitFor(() => Row(deep) > 0 && Row(other) > 0), 'first level was not listed')
  Toggle(deep)
  assert_true(WaitFor(() => Row(leaf) > 0), 'deep was not listed')
  assert_true(index(simpletree#TestGetState().caps, 'watch') >= 0, 'native watcher is required')

  Toggle(deep)
  assert_true(WaitFor(() => Row(leaf) == 0 && has_key(Vars().s_cache, deep)), 'collapsed cache not warmed')
  assert_true(index(simpletree#TestGetState().watched, deep) < 0, 'collapsed dir was still watched')
  writefile(['deep/hide-me.txt'], policy)
  assert_true(WaitFor(() => !has_key(Vars().s_cache, deep)), 'policy did not invalidate the collapsed cache')
  assert_true(has_key(Vars().s_cache, sibling) && Row(other) > 0, 'unrelated sibling disappeared')
  Toggle(deep)
  assert_true(WaitFor(() => has_key(Vars().s_cache, deep)), 'deep was not rescanned')
  assert_equal([], filter(copy(Vars().s_cache[deep]), (_, entry) => get(entry, 'name', '') ==# 'hide-me.txt'),
    'ignored leaf returned on re-expand')

  # The same edit must update a descendant that is still open, in place.
  writefile([], policy)
  assert_true(WaitFor(() => Row(leaf) > 0), 'clearing the policy did not restore the expanded leaf')
  var next = branch .. '/next-ignore'
  writefile(['deep/hide-me.txt'], next)
  assert_equal(0, rename(next, policy))
  assert_true(WaitFor(() => Row(leaf) == 0), 'replacing the policy did not hide the expanded leaf')
  assert_equal(0, delete(policy))
  assert_true(WaitFor(() => Row(leaf) > 0), 'removing the policy did not restore the expanded leaf')
  assert_true(Row(other) > 0, 'similarly prefixed sibling did not remain visible')

  var root_policy = project .. '/.gitignore'
  writefile(['branch/deep/hide-me.txt', 'branch-other/keep-me.txt'], root_policy)
  assert_true(WaitFor(() => Row(leaf) == 0 && Row(other) == 0), 'root policy did not reach both branches')
  assert_equal(0, delete(root_policy))
  assert_true(WaitFor(() => Row(leaf) > 0 && Row(other) > 0), 'root policy removal did not reach both branches')

  simpletree#OnToggleGitIgnore()
  assert_true(WaitFor(() => Row(leaf) > 0 && Row(other) > 0), 'ignore-disabled control was not ready')
  writefile(['deep/hide-me.txt'], policy)
  # Give the actual event a chance to pass both debounce timers.
  sleep 500m
  assert_true(Row(leaf) > 0, 'disabled ignore policy still filtered the leaf')
catch
  assert_report('unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

silent! SimpleTreeClose
delete(base, 'rf')
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
