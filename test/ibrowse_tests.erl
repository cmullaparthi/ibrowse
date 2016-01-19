%%% File    : ibrowse_tests.erl
%%% Authors : Benjamin Lee <http://github.com/benjaminplee>
%%%           Dan Schwabe <http://github.com/dfschwabe>
%%%           Brian Richards <http://github.com/richbria>
%%% Description : Functional tests of the ibrowse library using a live test HTTP server
%%% Created : 18 November 2014 by Benjamin Lee <yardspoon@gmail.com>

-module(ibrowse_tests).

-include_lib("eunit/include/eunit.hrl").
-define(PER_TEST_TIMEOUT_SEC, 60).
-define(TIMEDTEST(Desc, Fun), {Desc, {timeout, ?PER_TEST_TIMEOUT_SEC, fun Fun/0}}).

-define(SERVER_PORT, 8181).
-define(BASE_URL, "http://localhost:" ++ integer_to_list(?SERVER_PORT)).
-define(SHORT_TIMEOUT_MS, 5000).
-define(LONG_TIMEOUT_MS, 30000).
-define(PAUSE_FOR_CONNECTIONS_MS, 2000).

-compile(export_all).

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
        ?TIMEDTEST("Pipeline depth goes down with responses", pipeline_depth),
        ?TIMEDTEST("Pipelines refill", pipeline_refill),
        ?TIMEDTEST("Timeout closes pipe", closing_pipes),
        ?TIMEDTEST("Requests are balanced over connections", balanced_connections),
        ?TIMEDTEST("Pipeline too small signals retries", small_pipeline),
        ?TIMEDTEST("Dest status can be gathered", status)
     ]
    }.

simple_request() ->
    ?assertMatch({ok, "200", _, _}, ibrowse:send_req(?BASE_URL, [], get, [], [])).

slow_server_timeout() ->
    ?assertMatch({error, req_timedout}, ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [], 5000)).

pipeline_depth() ->
    MaxSessions = 2,
    MaxPipeline = 2,
    RequestsSent = 2,
    EmptyPipelineDepth = 0,

    ?assertEqual([], ibrowse_test_server:get_conn_pipeline_depth()),

    Fun = fun() -> ibrowse:send_req(?BASE_URL, [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS) end,
    times(RequestsSent, fun() -> spawn_link(Fun) end),

    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),

    Counts = [Count || {_Pid, Count} <- ibrowse_test_server:get_conn_pipeline_depth()],
    ?assertEqual(MaxSessions, length(Counts)),
    ?assertEqual(lists:duplicate(MaxSessions, EmptyPipelineDepth), Counts).

pipeline_refill() ->
    MaxSessions = 2,
    MaxPipeline = 2,
    RequestsToFill = MaxSessions * MaxPipeline,

    %% Send off enough requests to fill sessions and pipelines in rappid succession
    Fun = fun() -> ibrowse:send_req(?BASE_URL, [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS) end,
    times(RequestsToFill, fun() -> spawn_link(Fun) end),
    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),

    % Verify that connections properly reported their completed responses and can still accept more
    ?assertMatch({ok, "200", _, _}, ibrowse:send_req(?BASE_URL, [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS)),

    % and do it again to make sure we really are clear
    times(RequestsToFill, fun() -> spawn_link(Fun) end),
    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),

    % Verify that connections properly reported their completed responses and can still accept more
    ?assertMatch({ok, "200", _, _}, ibrowse:send_req(?BASE_URL, [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS)).

closing_pipes() ->
    MaxSessions = 2,
    MaxPipeline = 2,
    RequestsSent = 2,
    BalancedNumberOfRequestsPerConnection = 1,

    ?assertEqual([], ibrowse_test_server:get_conn_pipeline_depth()),

    Fun = fun() -> ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS) end,
    times(RequestsSent, fun() -> spawn_link(Fun) end),

    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),

    Counts = [Count || {_Pid, Count} <- ibrowse_test_server:get_conn_pipeline_depth()],
    ?assertEqual(MaxSessions, length(Counts)),
    ?assertEqual(lists:duplicate(MaxSessions, BalancedNumberOfRequestsPerConnection), Counts),

    timer:sleep(?SHORT_TIMEOUT_MS),

    ?assertEqual([], ibrowse_test_server:get_conn_pipeline_depth()).

balanced_connections() ->
    MaxSessions = 4,
    MaxPipeline = 100,
    RequestsSent = 80,
    BalancedNumberOfRequestsPerConnection = 20,

    ?assertEqual([], ibrowse_test_server:get_conn_pipeline_depth()),

    Fun = fun() -> ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?LONG_TIMEOUT_MS) end,
    times(RequestsSent, fun() -> spawn_link(Fun) end),

    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),

    Counts = [Count || {_Pid, Count} <- ibrowse_test_server:get_conn_pipeline_depth()],
    ?assertEqual(MaxSessions, length(Counts)),

    ?assertEqual(lists:duplicate(MaxSessions, BalancedNumberOfRequestsPerConnection), Counts).

small_pipeline() ->
    MaxSessions = 10,
    MaxPipeline = 10,
    RequestsSent = 100,
    FullRequestsPerConnection = 10,

    ?assertEqual([], ibrowse_test_server:get_conn_pipeline_depth()),

    Fun = fun() -> ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS) end,
    times(RequestsSent, fun() -> spawn(Fun) end),

    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),  %% Wait for everyone to get in line

    ibrowse:show_dest_status("localhost", 8181),
    Counts = [Count || {_Pid, Count} <- ibrowse_test_server:get_conn_pipeline_depth()],
    ?assertEqual(MaxSessions, length(Counts)),

    ?assertEqual(lists:duplicate(MaxSessions, FullRequestsPerConnection), Counts),

    Response = ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS),

    ?assertEqual({error, retry_later}, Response).

status() ->
    MaxSessions = 10,
    MaxPipeline = 10,
    RequestsSent = 100,

    Fun = fun() -> ibrowse:send_req(?BASE_URL ++ "/never_respond", [], get, [], [{max_sessions, MaxSessions}, {max_pipeline_size, MaxPipeline}], ?SHORT_TIMEOUT_MS) end,
    times(RequestsSent, fun() -> spawn(Fun) end),

    timer:sleep(?PAUSE_FOR_CONNECTIONS_MS),  %% Wait for everyone to get in line

    ibrowse:show_dest_status(),
    ibrowse:show_dest_status("http://localhost:8181").


times(0, _) ->
    ok;
times(X, Fun) ->
    Fun(),
    times(X - 1, Fun).
