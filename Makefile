CC=clang
CFLAGS=-Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0
all: build/magdot
build/magdot: src/magdot.c src/service.h
	mkdir -p build
	$(CC) $(CFLAGS) $< -framework IOKit -framework CoreFoundation -framework Security -o $@
clean:
	rm -rf build
