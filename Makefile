NAME := dcd

run:
	zig build
	@$(MAKE) install

# ReleaseSafe, not ReleaseFast: dcd should stop loudly on a bug rather than carry on
# with undefined behaviour and leave a screen dark.
prod:
	zig build -Doptimize=ReleaseSafe
	@$(MAKE) install

install:
	mkdir -p ~/bin
	rm -f ~/bin/$(NAME)
	cp zig-out/bin/$(NAME) ~/bin/$(NAME)

test:
	zig build test --summary all

watch:
	zig build run -- watch

.PHONY: run prod install test watch
