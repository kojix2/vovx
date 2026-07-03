.PHONY: help build spec clean

.DEFAULT_GOAL := help

CRYSTAL_FLAGS = -Dpreview_mt -Dexecution_context
BUILD_FLAGS =

ifeq ($(release),1)
BUILD_FLAGS += --release
endif

ifneq ($(LINK_FLAGS),)
BUILD_FLAGS += --link-flags="$(LINK_FLAGS)"
endif

help:
	@printf "Targets:\n"
	@printf "  make build        Build bin/vovx\n"
	@printf "  make spec         Run Crystal specs\n"
	@printf "  make clean        Remove build output and installed shards\n"
	@printf "\nOptions:\n"
	@printf "  release=1         Build with --release\n"
	@printf "  LINK_FLAGS=...    Pass linker flags to crystal\n"

build:
	shards build $(CRYSTAL_FLAGS) $(BUILD_FLAGS)

spec:
	crystal spec $(CRYSTAL_FLAGS)


clean:
	rm -f bin/vovx
	rm -rf lib
