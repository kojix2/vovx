.PHONY: build spec test run clean

CRYSTAL_FLAGS = -Dpreview_mt -Dexecution_context
CRYSTAL_CACHE_DIR = .crystal-cache

build:
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) shards build $(CRYSTAL_FLAGS)

spec:
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) crystal spec $(CRYSTAL_FLAGS)

test: spec

run: build
	bin/vovx

clean:
	rm -f bin/vovx
