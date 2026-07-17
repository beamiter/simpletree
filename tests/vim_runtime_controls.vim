vim9script

var repo = expand('<sfile>:p:h:h')
var state = tempname()
g:simpletree_width_state_file = state
g:simpletree_width_persist_delay = 20
g:simpletree_set_default_mapping = 0

execute 'set runtimepath^=' .. fnameescape(repo)
runtime plugin/simpletree.vim

new
vnew
setfiletype simpletree
vertical resize 33
g:SimpleTreeCaptureWidth()
sleep 60m
assert_equal(['33'], readfile(state))
assert_equal(33, g:simpletree_width)

assert_equal(1, g:simpletree_auto_refresh)
g:SimpleTreeToggleAutoRefresh()
assert_equal(0, g:simpletree_auto_refresh)
g:SimpleTreeToggleAutoRefresh()
assert_equal(1, g:simpletree_auto_refresh)

assert_equal(1, g:simpletree_auto_follow)
g:SimpleTreeToggleAutoFollow()
assert_equal(0, g:simpletree_auto_follow)

assert_equal(2, exists(':SimpleTreeVersion'))
assert_equal(2, exists(':SimpleTreeToggleAutoRefresh'))
assert_equal(2, exists(':SimpleTreeToggleAutoFollow'))

if filereadable(state)
  delete(state)
endif
if len(v:errors) > 0
  writefile(v:errors, '/tmp/simpletree-vim-runtime-errors')
  cquit
endif
qa!
