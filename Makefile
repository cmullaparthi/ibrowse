IBROWSE_VSN = $(shell sed -n 's/.*{vsn,.*"\(.*\)"}.*/\1/p' src/ibrowse.app.src)

DIALYZER_PLT=$(CURDIR)/.dialyzer_plt
DIALYZER_APPS=erts kernel stdlib ssl crypto public_key

all: compile

compile:
	./rebar compile

clean:
	./rebar clean

install: compile
	mkdir -p $(DESTDIR)/lib/ibrowse-$(IBROWSE_VSN)/
	cp -r ebin $(DESTDIR)/lib/ibrowse-$(IBROWSE_VSN)/

test: all
	./rebar eunit
	erl -noshell -pa .eunit -pa test -s ibrowse -s ibrowse_test unit_tests \
	-s ibrowse_test verify_chunked_streaming \
	-s ibrowse_test test_chunked_streaming_once \
	-s erlang halt

xref: all
	./rebar xref

docs:
	erl -noshell \
		-eval 'edoc:application(ibrowse, ".", []), init:stop().'

$(DIALYZER_PLT):
	@echo Creating dialyzer plt file: $(DIALYZER_PLT)
	@echo This may take a minute or two...
	@echo
	dialyzer --output_plt $(DIALYZER_PLT) --build_plt \
	   --apps $(DIALYZER_APPS)

dialyzer: $(DIALYZER_PLT)
	@echo Running dialyzer...
	@echo
	dialyzer --fullpath --plt $(DIALYZER_PLT) -Wrace_conditions -Wunmatched_returns -Werror_handling -r ./ebin
