CC ?= gcc
CFLAGS ?= -std=c99 -Wall -Wextra -pedantic
LDFLAGS ?=

EXAMPLES = examples/sync_get examples/async_post

ifeq ($(OS),Windows_NT)
EXEEXT = .exe
LDLIBS += -lwinhttp
else ifeq ($(shell uname -s),Darwin)
LDLIBS += -framework CoreFoundation -framework CFNetwork
else
LDLIBS += -ldl
endif

all: $(EXAMPLES:%=%$(EXEEXT))

examples/sync_get$(EXEEXT): examples/sync_get.c tinyrequests.h
	$(CC) $(CFLAGS) -o $@ examples/sync_get.c $(LDFLAGS) $(LDLIBS)

examples/async_post$(EXEEXT): examples/async_post.c tinyrequests.h
	$(CC) $(CFLAGS) -o $@ examples/async_post.c $(LDFLAGS) $(LDLIBS)

clean:
	$(RM) examples/sync_get examples/sync_get.exe examples/async_post examples/async_post.exe

.PHONY: all clean
