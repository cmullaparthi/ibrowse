REBAR ?= $(shell which rebar3)

all: compile
	erl -noshell -boot start_clean -pa ../../ibrowse/ebin -s ibrowse_test local_unit_tests -s erlang halt

compile:
	erl -pa ../../ibrowse/ebin -make

clean:
	$(REBAR) clean
