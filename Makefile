PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: install uninstall test lint

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 bin/mmonitctl "$(DESTDIR)$(BINDIR)/mmonitctl"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/mmonitctl"

test:
	sh tests/test.sh

lint:
	sh -n bin/mmonitctl tests/test.sh
