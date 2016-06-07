IBROWSE_EBIN_PATH=../../ibrowse/ebin

compile:
	@erl -pa $(IBROWSE_EBIN_PATH) -make

test: compile
	@erl -noshell -boot start_clean -pa $(IBROWSE_EBIN_PATH) -s ibrowse_test local_unit_tests -s erlang halt

old_tests: compile
	@erl -noshell -boot start_clean -pa $(IBROWSE_EBIN_PATH) -s ibrowse_test unit_tests -s erlang halt

test_shell: compile
	erl -boot start_clean -pa $(IBROWSE_EBIN_PATH) -s ibrowse_test_server start_server

clean:
	@rm -f *.beam
