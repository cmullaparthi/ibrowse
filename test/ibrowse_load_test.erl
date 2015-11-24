-module(ibrowse_load_test).
-compile(export_all).

-define(ibrowse_load_test_counters, ibrowse_load_test_counters).

start(Num_workers, Num_requests, Max_sess) ->
    proc_lib:spawn(fun() ->
                           start_1(Num_workers, Num_requests, Max_sess)
                   end).

query_state() ->
    ibrowse_load_test ! query_state.

shutdown() ->
    ibrowse_load_test ! shutdown.

start_1(Num_workers, Num_requests, Max_sess) ->
    register(ibrowse_load_test, self()),
    application:start(ibrowse),
    application:set_env(ibrowse, inactivity_timeout, 5000),
    Ulimit = os:cmd("ulimit -n"),
    case catch list_to_integer(string:strip(Ulimit, right, $\n)) of
        X when is_integer(X), X > 3000 ->
            ok;
        X ->
            io:format("Load test not starting. {insufficient_value_for_ulimit, ~p}~n", [X]),
            exit({insufficient_value_for_ulimit, X})
    end,
    ets:new(?ibrowse_load_test_counters, [named_table, public]),
    ets:new(ibrowse_load_timings, [named_table, public]),
    try
        ets:insert(?ibrowse_load_test_counters, [{success, 0},
                                                 {failed, 0},
                                                 {timeout, 0},
                                                 {retry_later, 0},
                                                 {one_request_only, 0}
                                                ]),
        ibrowse:set_max_sessions("localhost", 8081, Max_sess),
        Start_time    = os:timestamp(),
        Workers       = spawn_workers(Num_workers, Num_requests),
        erlang:send_after(1000, self(), print_diagnostics),
        ok            = wait_for_workers(Workers),
        End_time      = os:timestamp(),
        Time_in_secs  = trunc(round(timer:now_diff(End_time, Start_time) / 1000000)),
        Req_count     = Num_workers * Num_requests,
        [{_, Success_count}] = ets:lookup(?ibrowse_load_test_counters, success),
        case Success_count == Req_count of
            true ->
                io:format("Test success. All requests succeeded~n", []);
            false when Success_count > 0 ->
                io:format("Test failed. Some successes~n", []);
            false ->
                io:format("Test failed. ALL requests FAILED~n", [])
        end,
        case Time_in_secs > 0 of
            true ->
                io:format("Reqs/sec achieved : ~p~n", [trunc(round(Success_count / Time_in_secs))]);
            false ->
                ok
        end,
        io:format("Load test results:~n~p~n", [ets:tab2list(?ibrowse_load_test_counters)]),
        io:format("Timings: ~p~n", [calculate_timings()])
    catch Err ->
            io:format("Err: ~p~n", [Err])
    after
        ets:delete(?ibrowse_load_test_counters),
        ets:delete(ibrowse_load_timings),
        unregister(ibrowse_load_test)
    end.

calculate_timings() ->
    {Max, Min, Mean} = get_mmv(ets:first(ibrowse_load_timings), {0, 9999999, 0}),
    Variance = trunc(round(ets:foldl(fun({_, X}, X_acc) ->
                                             (X - Mean)*(X-Mean) + X_acc
                                     end, 0, ibrowse_load_timings) / ets:info(ibrowse_load_timings, size))),
    Std_dev = trunc(round(math:sqrt(Variance))),
    {ok, [{max, Max},
          {min, Min},
          {mean, Mean},
          {variance, Variance},
          {standard_deviation, Std_dev}]}.

get_mmv('$end_of_table', {Max, Min, Total}) ->
    Mean = trunc(round(Total / ets:info(ibrowse_load_timings, size))),
    {Max, Min, Mean};
get_mmv(Key, {Max, Min, Total}) ->
    [{_, V}] = ets:lookup(ibrowse_load_timings, Key),
    get_mmv(ets:next(ibrowse_load_timings, Key), {max(Max, V), min(Min, V), Total + V}).


spawn_workers(Num_w, Num_r) ->
    spawn_workers(Num_w, Num_r, self(), []).

spawn_workers(0, _Num_requests, _Parent, Acc) ->
    lists:reverse(Acc);
spawn_workers(Num_workers, Num_requests, Parent, Acc) ->
    Pid_ref = spawn_monitor(fun() ->
                                    random:seed(os:timestamp()),
                                    case catch worker_loop(Parent, Num_requests) of
                                        {'EXIT', Rsn} ->
                                            io:format("Worker crashed with reason: ~p~n", [Rsn]);
                                        _ ->
                                            ok
                                    end
                            end),
    spawn_workers(Num_workers - 1, Num_requests, Parent, [Pid_ref | Acc]).

wait_for_workers([]) ->
    ok;
wait_for_workers([{Pid, Pid_ref} | T] = Pids) ->
    receive
        {done, Pid} ->
            wait_for_workers(T);
        {done, Some_pid} ->
            wait_for_workers([{Pid, Pid_ref} | lists:keydelete(Some_pid, 1, T)]);
        print_diagnostics ->
            io:format("~1000.p~n", [ibrowse:get_metrics()]),
            erlang:send_after(1000, self(), print_diagnostics),
            wait_for_workers(Pids);
        query_state ->
            io:format("Waiting for ~p~n", [Pids]),
            wait_for_workers(Pids);
        shutdown ->
            io:format("Shutting down on command. Still waiting for ~p workers~n", [length(Pids)]);
        {'DOWN', _, process, _, normal} ->
            wait_for_workers(Pids);
        {'DOWN', _, process, Down_pid, Rsn} ->
            io:format("Worker ~p died. Reason: ~p~n", [Down_pid, Rsn]),
            wait_for_workers(lists:keydelete(Down_pid, 1, Pids));
        X ->
            io:format("Recvd unknown msg: ~p~n", [X]),
            wait_for_workers(Pids)
    end.

worker_loop(Parent, 0) ->
    Parent ! {done, self()};
worker_loop(Parent, N) ->
    Delay = random:uniform(100),
    Url = case Delay rem 10 of
              %% Change 10 to some number between 0-9 depending on how
              %% much chaos you want to introduce into the server
              %% side. The higher the number, the more often the
              %% server will close a connection after serving the
              %% first request, thereby forcing the client to
              %% retry. Any number of 10 or higher will disable this
              %% chaos mechanism
              10 ->
                  ets:update_counter(?ibrowse_load_test_counters, one_request_only, 1),
                  "http://localhost:8081/ibrowse_handle_one_request_only";
              _ ->
                  "http://localhost:8081/blah"
          end,
    Start_time = os:timestamp(),
    Res = ibrowse:send_req(Url, [], get),
    End_time = os:timestamp(),
    Time_taken = trunc(round(timer:now_diff(End_time, Start_time) / 1000)),
    ets:insert(ibrowse_load_timings, {os:timestamp(), Time_taken}),
    case Res of
        {ok, "200", _, _} ->
            ets:update_counter(?ibrowse_load_test_counters, success, 1);
        {error, req_timedout} ->
            ets:update_counter(?ibrowse_load_test_counters, timeout, 1);
        {error, retry_later} ->
            ets:update_counter(?ibrowse_load_test_counters, retry_later, 1);
        {error, Reason} ->
            update_unknown_counter(Reason, 1);
        _ ->
            io:format("~p -- Res: ~p~n", [self(), Res]),
            ets:update_counter(?ibrowse_load_test_counters, failed, 1)
    end,
    timer:sleep(Delay),
    worker_loop(Parent, N - 1).

update_unknown_counter(Counter, Inc_val) ->
    case catch ets:update_counter(?ibrowse_load_test_counters, Counter, Inc_val) of
        {'EXIT', _} ->
            ets:insert_new(?ibrowse_load_test_counters, {Counter, 0}),
            update_unknown_counter(Counter, Inc_val);
        _ ->
            ok
    end.
