-module(ibrowse_load_test).
-export([go/3]).

-define(counters, ibrowse_load_test_counters).

go(URL, N_workers, N_reqs) ->
    spawn(fun() ->
                  go_1(URL, N_workers, N_reqs)
          end).

go_1(URL, N_workers, N_reqs) ->
    ets:new(?counters, [named_table, public]),
    try
        ets:insert(?counters, [{success, 0},
                               {failed, 0},
                               {timeout, 0},
                               {retry_later, 0}]),
        Start_time = now(),
        Pids = spawn_workers(N_workers, N_reqs, URL, self(), []),
        wait_for_pids(Pids),
        End_time = now(),
        Time_taken = trunc(round(timer:now_diff(End_time, Start_time) / 1000000)),
        [{_, Success_reqs}] = ets:lookup(?counters, success),
        Total_reqs = N_workers*N_reqs,
        Req_rate = case Time_taken > 0 of
                       true ->
                           trunc(Success_reqs / Time_taken);
                       false when Success_reqs == Total_reqs ->
                           withabix;
                       false ->
                           without_a_bix
                   end,
        io:format("Stats      : ~p~n", [ets:tab2list(?counters)]),
        io:format("Total reqs : ~p~n", [Total_reqs]),
        io:format("Time taken : ~p seconds~n", [Time_taken]),
        io:format("Reqs / sec : ~p~n", [Req_rate])
    catch Class:Reason ->
            io:format("Load test crashed. Reason: ~p~n"
                      "Stacktrace : ~p~n",
                      [{Class, Reason}, erlang:get_stacktrace()])
    after
        ets:delete(?counters)
    end.

spawn_workers(0, _, _, _, Acc) ->
    Acc;
spawn_workers(N_workers, N_reqs, URL, Parent, Acc) ->
    Pid = spawn(fun() ->
                        worker(N_reqs, URL, Parent)
                end),
    spawn_workers(N_workers - 1, N_reqs, URL, Parent, [Pid | Acc]).

wait_for_pids([Pid | T]) ->
    receive
        {done, Pid} ->
            wait_for_pids(T);
        {done, Some_pid} ->
            wait_for_pids([Pid | (T -- [Some_pid])])
    end;
wait_for_pids([]) ->
    ok.


worker(0, _, Parent) ->
    Parent ! {done, self()};
worker(N, URL, Parent) ->
    case ibrowse:send_req(URL, [], get) of
        {ok, "200", _, _} ->
            ets:update_counter(?counters, success, 1);
        {error, req_timedout} ->
            ets:update_counter(?counters, timeout, 1);
        {error, retry_later} ->
            ets:update_counter(?counters, retry_later, 1);
        _ ->
            ets:update_counter(?counters, failed, 1)
    end,
    worker(N - 1, URL, Parent).
