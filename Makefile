# Needs Agentica 0.24.4 or later on PATH (CI pins it). Every target runs in each folder that has an agentica.toml.
AGENTICA ?= agentica
PACKAGES := $(patsubst %/agentica.toml,%,$(wildcard */agentica.toml))
# How many test files of a package run at once.
JOBS ?= 4

.PHONY: help install check fmt-check test

help:
	@echo "install    fetch the packages of each agentica.lock into deps/"
	@echo "check      type-check every .agc file of each package"
	@echo "fmt-check  fail when a file is not formatted (agentica fmt)"
	@echo "test       run the features of specs/ and the tests of test/ of each package"

# A package with no dependencies has no lock and nothing to fetch.
install:
	@set -e; for p in $(PACKAGES); do \
		if [ -f $$p/agentica.lock ]; then echo "== $$p"; (cd $$p && $(AGENTICA) install); fi; \
	done

check:
	@set -e; for p in $(PACKAGES); do echo "== $$p"; (cd $$p && $(AGENTICA) check); done

fmt-check:
	@set -e; for p in $(PACKAGES); do echo "== $$p"; (cd $$p && $(AGENTICA) fmt --check); done

test:
	@set -e; for p in $(PACKAGES); do echo "== $$p"; (cd $$p && $(AGENTICA) test --jobs $(JOBS)); done
