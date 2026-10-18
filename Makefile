NAME   := stripe-mrr
LABEL  := local.stripe-mrr
BIN    := $(HOME)/.local/bin/$(NAME)
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
DOMAIN := gui/$(shell id -u)

build/$(NAME): main.swift
	mkdir -p build
	swiftc -O -o $@ main.swift

.PHONY: print install uninstall

# Compute MRR once and print a per-subscription breakdown.
print: build/$(NAME)
	./build/$(NAME) --print

# Install the binary and a LaunchAgent so it starts at login.
install: build/$(NAME)
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	mkdir -p $(dir $(BIN)) $(dir $(PLIST))
	install -m 755 build/$(NAME) $(BIN)
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BIN@|$(BIN)|' launchagent.plist > $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST)

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL)
	rm -f $(BIN) $(PLIST)
