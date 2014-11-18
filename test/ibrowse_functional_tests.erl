%%% File    : ibrowse_functional_tests.erl
%%% Authors : Benjamin Lee <yardspoon@gmail.com>
%%%           Brian Richards <bmrichards16@gmail.com>
%%% Description : Functional tests of the ibrowse library using a live test HTTP server
%%% Created : 18 November 2014 by Benjamin Lee <yardspoon@gmail.com>

-module(ibrowse_functional_tests).

-include_lib("eunit/include/eunit.hrl").
-define(PER_TEST_TIMEOUT_SEC, 60).
-define(TIMEDTEST(Desc, Fun), {Desc, {timeout, ?PER_TEST_TIMEOUT_SEC, fun Fun/0}}).

-define(SERVER_PORT, 8181).
-define(BASE_URL, "http://localhost:" ++ integer_to_list(?SERVER_PORT)).

setup() ->
    application:start(crypto),
    application:start(public_key),
    application:start(ssl),
    ibrowse_test_server:start_server(?SERVER_PORT, tcp),
    ibrowse:start(),
    ok.

teardown(_) ->
    ibrowse:stop(),
    ibrowse_test_server:stop_server(?SERVER_PORT),
    ok.

running_server_fixture_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
        ?TIMEDTEST("Simple request can be honored", simple_request),
        ?TIMEDTEST("Slow server causes timeout", slow_server_timeout),
        ?TIMEDTEST("Requests are balanced over connections", balanced_connections)
     ]
    }.

simple_request() ->
    ?assertMatch({ok, "200", _, _}, ibrowse:send_req(?BASE_URL, [], get, [], [])).

slow_server_timeout() ->
    ?assertMatch({error, req_timedout}, ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [], 5000)).

balanced_connections() ->
    MaxSessions = 4,
    MaxPipeline = 100,
    RequestsSent = 80,
    BalancedNumberOfRequestsPerConnection = 20,

    ?assertEqual([], ibrowse_test_server:get_conn_pipeline_depth()),

    Fun = fun() -> ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], 30000) end,
    times(RequestsSent, fun() -> spawn_link(Fun) end),

    timer:sleep(1000),

    Diffs = [Count - BalancedNumberOfRequestsPerConnection || {_Pid, Count} <- ibrowse_test_server:get_conn_pipeline_depth()],
    ?assertEqual(MaxSessions, length(Diffs)),

    lists:foreach(fun(X) -> ?assertEqual(yep, close_to_zero(X)) end, Diffs).

close_to_zero(0) -> yep;
close_to_zero(-1) -> yep;
close_to_zero(1) -> yep;
close_to_zero(X) -> {nope, X}.

times(0, _) ->
    ok;
times(X, Fun) ->
    Fun(),
    times(X - 1, Fun).
