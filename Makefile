.PHONY: build spec test run clean

CRYSTAL_FLAGS = -Dpreview_mt -Dexecution_context
BUILD_FLAGS =

ifeq ($(release),1)
BUILD_FLAGS += --release
endif

ifneq ($(LINK_FLAGS),)
BUILD_FLAGS += --link-flags="$(LINK_FLAGS)"
endif

build:
	shards build $(CRYSTAL_FLAGS) $(BUILD_FLAGS)

spec:
	crystal spec $(CRYSTAL_FLAGS)

test: spec

run: build
	bin/vovx

clean:
	rm -f bin/vovx
