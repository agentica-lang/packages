# Needs Agentica 0.27.0 or later on PATH (CI pins it). Every target runs in each folder that has an agentica.toml.
AGENTICA ?= agentica
# CI passes the changed packages: make test PACKAGES="prop native-gen" (a command line value wins over this line).
PACKAGES := $(patsubst %/agentica.toml,%,$(wildcard */agentica.toml))
# How many test files of a package run at once.
JOBS ?= 4

.PHONY: help install check fmt-check test doc-examples doc-examples-test site site-mounts site-serve site-tools

help:
	@echo "install    fetch the packages of each agentica.lock into deps/"
	@echo "check      type-check every .agc file of each package"
	@echo "fmt-check  fail when a file is not formatted (agentica fmt)"
	@echo "test       run the features of specs/ and the tests of test/ of each package"
	@echo "doc-examples run the agentica code blocks of the docs/ of each package (tools/doc_examples.agc)"
	@echo "doc-examples-test check that tools/doc_examples.agc fails on its fixture (doc-examples runs it first)"
	@echo "site       build the documentation site into site/public (the docs/ folder of each package)"
	@echo "site-serve serve the site on localhost for a preview"

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

# The examples of each docs/ folder: a block with `def main` runs (and matches the `output` block after it), any other
# is checked; the rules are in the header of tools/doc_examples.agc.
doc-examples: doc-examples-test
	$(AGENTICA) tools/doc_examples.agc $(AGENTICA) $(PACKAGES)

# The fixture page has one block or fence per rule that fails, so the tool must exit 1 with exactly this summary and
# one located line (page:line:) per failure on stderr.
DOC_EXAMPLES_FIXTURE := tools/fixtures/doc_examples
DOC_EXAMPLES_FIXTURE_FAILED := 9
DOC_EXAMPLES_FIXTURE_SUMMARY := doc examples: 3 passed, $(DOC_EXAMPLES_FIXTURE_FAILED) failed, 1 fragments skipped
doc-examples-test:
	@errors=$$(mktemp); \
	summary=$$($(AGENTICA) tools/doc_examples.agc $(AGENTICA) $(DOC_EXAMPLES_FIXTURE) 2>$$errors); code=$$?; \
	located=$$(grep -cE '^$(DOC_EXAMPLES_FIXTURE)/docs/_index.md:[0-9]+:' $$errors); rm -f $$errors; \
	if [ $$code -ne 1 ] || [ "$$summary" != "$(DOC_EXAMPLES_FIXTURE_SUMMARY)" ] \
		|| [ "$$located" != "$(DOC_EXAMPLES_FIXTURE_FAILED)" ]; then \
		echo "doc-examples-test: expected exit 1, '$(DOC_EXAMPLES_FIXTURE_SUMMARY)' and $(DOC_EXAMPLES_FIXTURE_FAILED)" \
			"located lines; got exit $$code, '$$summary' and $$located"; \
		exit 1; \
	fi; echo "doc-examples-test: ok"

# The documentation site (Hugo): the look, the layouts and the highlighter come from the docs theme, the submodule
# site/themes/docs-theme; the pages are the docs/ folder of each package. The theme's styles need Dart Sass.
HUGO ?= hugo
THEME := site/themes/docs-theme
DART_SASS ?= $(HOME)/.local/opt/dart-sass
site site-serve: export PATH := $(DART_SASS):$(PATH)
# Each docs/ folder is mounted as content/PACKAGE, so a package adds its docs by having the folder.
PACKAGE_DOCS := $(wildcard $(addsuffix /docs,$(PACKAGES)))
HUGO_CONFIG := --source site --config hugo.toml,mounts.toml

# Rewritten on every run: a new package or a removed docs/ folder shows at once.
site-mounts:
	@{ printf '[[module.mounts]]\n  source = "content"\n  target = "content"\n\n'; \
	for d in $(PACKAGE_DOCS); do \
		printf '[[module.mounts]]\n  source = "../%s"\n  target = "content/%s"\n\n' "$$d" "$${d%/docs}"; \
	done; } > site/mounts.toml

# The theme and Dart Sass must be there before Hugo runs.
site-tools:
	@test -e $(THEME)/hugo.toml || { echo "The site needs its theme: git submodule update --init $(THEME)" >&2; exit 1; }
	@command -v sass >/dev/null || { echo "The site needs Dart Sass, on PATH or in $(DART_SASS)" >&2; exit 1; }

# The highlighter colors the Agentica code blocks after Hugo built the pages.
$(THEME)/highlight/node_modules: $(THEME)/highlight/package.json $(THEME)/highlight/package-lock.json
	npm ci --prefix $(THEME)/highlight --ignore-scripts --no-audit --no-fund
	touch $@

# --panicOnWarning: a link to a page that does not exist fails the build. --strict: the docs have agentica and
# signature blocks; --allow-unused-classes: their code does not use every color class of the grammar.
site: site-tools site-mounts $(THEME)/highlight/node_modules
	$(HUGO) $(HUGO_CONFIG) --cleanDestinationDir --panicOnWarning $(HUGO_FLAGS)
	node $(THEME)/highlight/highlight.mjs --strict --allow-unused-classes site/public

# Agentica blocks stay plain here: the highlighter runs in `make site`.
site-serve: site-tools site-mounts
	$(HUGO) server $(HUGO_CONFIG)
