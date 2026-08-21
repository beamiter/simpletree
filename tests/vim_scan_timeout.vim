vim9script

set nocompatible
set nomore
set hidden

var root = fnamemodify(expand('<sfile>:p:h'), ':h')
var daemon = root .. '/tests/fake_tree_daemon.py'
if !executable(daemon)
  setfperm(daemon, 'rwxr-xr-x')
endif
var workspace = tempname()
mkdir(workspace, 'p')
writefile(['one'], workspace .. '/one.txt')

$SIMPLETREE_FAKE_SILENT_LIST = '1'
g:simpletree_daemon_path = daemon
g:simpletree_persist_width = 0
g:simpletree_scan_timeout = 100
g:simpletree_state_file = tempname() .. '/state.json'
g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
execute 'set runtimepath^=' .. fnameescape(root)
execute 'source ' .. fnameescape(root .. '/plugin/simpletree.vim')

def Sid(): number
  return getscriptinfo({name: 'autoload/simpletree.vim'})[0].sid
enddef

def Vars(): dict<any>
  return getscriptinfo({sid: Sid()})[0].variables
enddef

def WaitFor(Condition: func(): bool, label: string, timeout_ms: number = 3000): bool
  for _ in range(timeout_ms / 10)
    if Condition()
      return true
    endif
    sleep 10m
  endfor
  assert_true(false, 'timeout: ' .. label)
  return false
enddef

execute 'SimpleTree ' .. fnameescape(workspace)
WaitFor(() => has_key(Vars().s_scan_errors, workspace),
  'the silent directory scan reaches its deadline')
var state = Vars()
assert_match('scan timed out', get(state.s_scan_errors, workspace, ''))
assert_false(has_key(state.s_loading, workspace),
  'a timed-out scan left the directory loading')
assert_false(has_key(state.s_pending, workspace),
  'a timed-out scan left the path pending')
assert_equal(0, len(state.s_bcbs),
  'a timed-out scan leaked its callback')

silent! SimpleTreeClose
simpletree#Stop()
$SIMPLETREE_FAKE_SILENT_LIST = ''
delete(workspace, 'rf')
if !empty(v:errors)
  writefile(v:errors, root .. '/tests/scan-timeout-errors.log')
  cquit!
endif
delete(root .. '/tests/scan-timeout-errors.log')
qall!
