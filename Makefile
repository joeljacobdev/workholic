.PHONY: install build

# make install bumps the version, builds the menu-bar app, and puts it in ~/Applications.

install:
	@version=$$(($$(cat version.txt) + 1)); \
	echo $$version > version.txt; \
	echo "Building Workholic $$version"; \
	VERSION=$$version macos/scripts/build-app.sh; \
	dest="$$HOME/Applications/Workholic.app"; \
	mkdir -p "$$HOME/Applications"; \
	if pid=$$(pgrep -x Workholic); then kill $$pid || true; sleep 0.5; fi; \
	rm -rf "$$dest"; \
	cp -R macos/dist/Workholic.app "$$dest"; \
	open "$$dest"; \
	echo "Installed $$dest (version $$version)"

build:
	macos/scripts/build-app.sh
