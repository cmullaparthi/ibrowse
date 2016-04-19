IBROWSE_VSN = $(shell sed -n 's/.*{vsn,.*"\(.*\)"}.*/\1/p' src/ibrowse.app.src)

DIALYZER_PLT=$(CURDIR)/.dialyzer_plt
DIALYZER_APPS=erts kernel stdlib ssl crypto public_key

REBAR ?= $(shell which rebar3)

all: compile

compile:
	$(REBAR) compile

clean:
	@$(REBAR) clean && cd test && make clean && cd ..

test: compile unit_tests eunit
	@echo "====================================================="

unit_tests:
	@echo "====================================================="
	@echo "Running tests..."
	@cd test && make test && cd ..

old_tests:
	@echo "====================================================="
	@echo "Running old tests..."
	@cd test && make old_tests && cd ..

eunit:
	@echo "====================================================="
	@echo "Running eunit tests..."
	$(REBAR) eunit --dir="src" 

xref: all
	$(REBAR) xref

docs:
	$(REBAR) edoc

dialyzer:
	$(REBAR) dialyzer


install: compile
	mkdir -p $(DESTDIR)/lib/ibrowse-$(IBROWSE_VSN)/
	cp -r _build/lib/default/ibrowse/ebin $(DESTDIR)/lib/ibrowse-$(IBROWSE_VSN)/

.PHONY: test docs
