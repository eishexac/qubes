# qubes - fan-out build and checks.
#
# Every directory holding a Makefile is a project. The top level owns
# nothing but the loop, so adopting or removing a project never edits this
# file. The contract a project's Makefile must honour:
#
#     check    lint and test itself; exit non-zero on any failure
#     verify   prove its built artifact behaves (determinism and the like)
#     build    produce its artifacts
#     clean    remove them
#     version  print the project's version, one line -- release tags are
#              <project>-v<version>, and CI matches them against this
#
# `check` also covers the shared tooling in this directory: the airlock
# script is linted and exercised here because it belongs to the
# repository, not to any one project.

PYTHON ?= python3

PROJECTS := $(patsubst %/Makefile,%,$(wildcard */Makefile))

# strip, or empty wildcards leave a lone space that reads as non-empty.
SELF_SHELL := $(strip $(wildcard bootstrap.sh) $(wildcard dom0/airlock) $(wildcard test/*.sh))

.PHONY: all build check verify clean self-check

all: build

build verify clean:
	@if [ -z "$(PROJECTS)" ]; then echo "no projects yet"; exit 0; fi
	@for p in $(PROJECTS); do \
		echo "== $$p: $@ =="; \
		$(MAKE) -C $$p $@ || exit 1; \
	done

check: self-check
	@if [ -z "$(PROJECTS)" ]; then echo "no projects yet"; exit 0; fi
	@for p in $(PROJECTS); do \
		echo "== $$p: check =="; \
		$(MAKE) -C $$p check || exit 1; \
	done

# Same standard the projects hold themselves to: a linter that is not
# installed is reported, never silently skipped as success.
self-check:
	@if [ -n "$(SELF_SHELL)" ]; then \
		for f in $(SELF_SHELL); do \
			sh -n "$$f" || exit 1; \
			printf 'sh -n ok: %s\n' "$$f"; \
		done; \
		if command -v shellcheck >/dev/null 2>&1; then \
			shellcheck -s sh $(SELF_SHELL) || exit 1; \
			printf 'shellcheck ok (top level)\n'; \
		else \
			printf 'shellcheck NOT INSTALLED - top-level shell unlinted\n'; \
		fi; \
	fi
	@for t in $(wildcard test/*.sh); do sh "$$t" || exit 1; done
