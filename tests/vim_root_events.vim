vim9script

set nocompatible
set nomore

var repo = fnamemodify(expand('<sfile>:p:h'), ':h')
var daemon = repo .. '/target/debug/simpletree-daemon'
if !executable(daemon)
  daemon = repo .. '/lib/simpletree-daemon'
endif
if !executable(daemon)
  echoerr 'daemon binary not found; build with cargo build first'
  cquit
endif

var base = tempname()
mkdir(base .. '/child', 'p')

g:simpletree_daemon_path = daemon
g:simpletree_persist_width = 0
g:simpletree_persist_state = 0
g:simpletree_root_locked = 0
execute 'set runtimepath^=' .. fnameescape(repo)
runtime plugin/simpletree.vim

g:root_events = []
augroup TestRootEvents
  autocmd!
  autocmd User SimpleTreeRootChanged
    \ call add(g:root_events, copy(g:simpletree_event))
augroup END

execute 'SimpleTree ' .. fnameescape(base)
assert_equal(1, len(g:root_events))
assert_equal(base, g:root_events[0].root)
assert_equal(base, g:root_events[0].path)
assert_equal('', g:root_events[0].old_root)
assert_equal('command', g:root_events[0].source)

assert_true(simpletree#ExternalSetRoot(base .. '/child', 'simpleremote'))
assert_equal(2, len(g:root_events))
assert_equal(base .. '/child', g:root_events[1].root)
assert_equal(base, g:root_events[1].old_root)
assert_equal('simpleremote', g:root_events[1].source)

simpletree#OnRootUp()
assert_equal(3, len(g:root_events))
assert_equal(base, g:root_events[2].root)
assert_equal(base .. '/child', g:root_events[2].old_root)
assert_equal('up', g:root_events[2].source)

SimpleTreeClose
delete(base, 'rf')
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
