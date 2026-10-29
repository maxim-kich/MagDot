CC=clang
CFLAGS=-Wall -Wextra -Werror -O2
all: build/magdot
build/magdot: src/magdot.c
	mkdir -p build
	$(CC) $(CFLAGS) $< -framework IOKit -framework CoreFoundation -o $@
clean:
	rm -rf build
