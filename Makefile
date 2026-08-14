.PHONY: check shell fmt clippy test vim-test vim-core defcompile core-verify doc-tags

check: core-verify shell doc-tags fmt clippy test defcompile vim-core vim-test

# `*word*` in a help file is not emphasis, it is a *global* tag definition, and
# doc/tags is what :help searches suite-wide.  One stray pair of asterisks in
# prose is enough to hijack `:help below` for every user who installs us, and
# nothing else in the build would ever notice.  So: regenerate the tags from a
# scratch copy of doc/, refuse any tag that is not ours, and refuse a committed
# doc/tags that no longer matches the help text it indexes.
doc-tags:
	@tmp=$$(mktemp -d) && cp doc/*.txt $$tmp/ && \
	vim -Nu NONE -n -i NONE -es -c "helptags $$tmp" -c 'qa!' </dev/null && \
	status=0; \
	foreign=$$(awk -F'\t' '$$1 !~ /^(simpletree|g:simpletree|:SimpleTree|<Plug>\(simpletree)/ { print $$1 }' $$tmp/tags); \
	if [ -n "$$foreign" ]; then \
	  echo "doc: *word* in prose defined a global help tag: $$foreign" >&2; status=1; fi; \
	if ! diff -u doc/tags $$tmp/tags >&2; then \
	  echo "doc/tags is stale; regenerate with :helptags doc" >&2; status=1; fi; \
	rm -rf $$tmp; \
	[ $$status -eq 0 ] && echo "doc: help tags are current and plugin-scoped"

# The installer is the only thing a user runs before any of the above can exist,
# so a syntax error in it is the one failure nothing else catches.  CI used to
# check this in a step of its own; it lives here so `make check` remains the
# whole gate and CI needs exactly one line.
shell:
	bash -n install.sh
	bash -n install-common.sh

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --locked

vim-test:
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_integration.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_v2_features.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_runtime_controls.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_render_cache.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_bookmarks.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_sorting.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_reveal.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_tabpages.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_marks.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_health.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_search.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_fsops.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_fsop_failures.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_filter.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_git_multi.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_columns.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_session_state.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_root_events.vim

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpletree/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
