.PHONY: install build hooks

# The version is bumped by each commit (.githooks/pre-commit), not here: an install builds the
# version in version.txt, so installing the same commit twice gives the same version.

install: hooks
	@version=$$(cat version.txt); \
	echo "Building Workholic $$version"; \
	macos/scripts/build-app.sh; \
	dest="$$HOME/Applications/Workholic.app"; \
	mkdir -p "$$HOME/Applications"; \
	if pid=$$(pgrep -x Workholic); then kill $$pid || true; sleep 0.5; fi; \
	rm -rf "$$dest"; \
	cp -R macos/dist/Workholic.app "$$dest"; \
	open "$$dest"; \
	echo "Installed $$dest (version $$version)"

build:
	macos/scripts/build-app.sh

# Turns on the hook that bumps version.txt with every commit.
hooks:
	@git config core.hooksPath .githooks
