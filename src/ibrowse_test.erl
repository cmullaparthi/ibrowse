%%% File    : ibrowse_test.erl
%%% Author  : Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%% Description : Test ibrowse
%%% Created : 14 Oct 2003 by Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>

-module(ibrowse_test).
-vsn('$Id: ibrowse_test.erl,v 1.1 2005/05/05 22:28:28 chandrusf Exp $ ').

-compile(export_all).
-import(ibrowse_http_client, [printable_date/0]).

send_reqs(Url, NumWorkers, NumReqsPerWorker) ->
    proc_lib:spawn(?MODULE, send_reqs_1, [Url, NumWorkers, NumReqsPerWorker]).

send_reqs_1(Url, NumWorkers, NumReqsPerWorker) ->
    process_flag(trap_exit, true),
    Pids = lists:map(fun(_X) ->
			     proc_lib:spawn_link(?MODULE, do_send_req, [Url, NumReqsPerWorker, self()])
		     end, lists:seq(1,NumWorkers)),
    put(num_reqs_per_worker, NumReqsPerWorker),
    do_wait(Pids, now(), printable_date(), 0, 0).

do_wait([], _StartNow, StartTime, NumSucc, NumErrs) ->
    io:format("~n~nDone...~nStartTime -> ~s~n", [StartTime]),
    io:format("EndTime -> ~s~n", [printable_date()]),
    io:format("NumSucc -> ~p~n", [NumSucc]),
    io:format("NumErrs -> ~p~n", [NumErrs]);
do_wait(Pids, StartNow, StartTime, NumSucc, NumErrs) ->
    receive
	{done, From, _Time, {ChildNumSucc, ChildNumFail}} ->
	    do_wait(Pids--[From], StartNow, StartTime, NumSucc+ChildNumSucc, NumErrs+ChildNumFail);
	{'EXIT',_, normal} ->
	    do_wait(Pids, StartNow, StartTime, NumSucc, NumErrs);
	{'EXIT', From, _Reason} ->
	    do_wait(Pids--[From], StartNow, StartTime, NumSucc, NumErrs + get(num_reqs_per_worker))
    end.
		     
do_send_req(Url, NumReqs, Parent) ->
    StartTime = now(),
    Res = do_send_req_1(Url, NumReqs, {0, 0}),
    Parent ! {done, self(), StartTime, Res}.

do_send_req_1(_Url, 0, {NumSucc, NumFail}) ->
    {NumSucc, NumFail};
do_send_req_1(Url, NumReqs, {NumSucc, NumFail}) ->
    case ibrowse:send_req(Url, [], get, [], [], 10000) of
	{ok, _Status, _Headers, _Body} ->
	    do_send_req_1(Url, NumReqs-1, {NumSucc+1, NumFail});
	_Err ->
	    do_send_req_1(Url, NumReqs-1, {NumSucc, NumFail+1})
    end.

drv_ue_test() ->
    drv_ue_test(lists:duplicate(1024, 127)).
drv_ue_test(Data) ->
    [{port, Port}| _] = ets:lookup(ibrowse_table, port),
%     erl_ddll:unload_driver("ibrowse_drv"),
%     timer:sleep(1000),
%     erl_ddll:load_driver("../priv", "ibrowse_drv"),
%     Port = open_port({spawn, "ibrowse_drv"}, []),
    {Time, Res} = timer:tc(ibrowse_lib, drv_ue, [Data, Port]),
    io:format("Time -> ~p~n", [Time]),
    io:format("Data Length -> ~p~n", [length(Data)]),
    io:format("Res Length -> ~p~n", [length(Res)]).
%    io:format("Result -> ~s~n", [Res]).

ue_test() ->
    ue_test(lists:duplicate(1024, $?)).
ue_test(Data) ->
    {Time, Res} = timer:tc(ibrowse_lib, url_encode, [Data]),
    io:format("Time -> ~p~n", [Time]),
    io:format("Data Length -> ~p~n", [length(Data)]),
    io:format("Res Length -> ~p~n", [length(Res)]).
%    io:format("Result -> ~s~n", [Res]).
