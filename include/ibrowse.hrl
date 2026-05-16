-ifndef(IBROWSE_HRL).
-define(IBROWSE_HRL, "ibrowse.hrl").

-record(url, {
          abspath,
          host,
          port,
          username,
          password,
          path,
          protocol,
          host_type  % 'hostname', 'ipv4_address' or 'ipv6_address'
}).

-record(lb_pid, {host_port, pid, ets_tid}).

-record(client_conn, {key, cur_pipeline_size = 0, reqs_served = 0}).

-record(ibrowse_conf, {key, value}).

-define(CONNECTIONS_LOCAL_TABLE, ibrowse_lb).
-define(LOAD_BALANCER_NAMED_TABLE, ibrowse_lb).
-define(CONF_TABLE, ibrowse_conf).
-define(STREAM_TABLE, ibrowse_stream).

-define(TRY_CATCH(F, A), ?TRY_CATCH(erlang, apply, [F, A])).
-define(TRY_CATCH(M, F, A),
    (fun() ->
        try
            apply(M, F, A)
        catch
            throw:__Term -> __Term;
            exit:__Reason -> {'EXIT', __Reason};
            error:__Reason:__Stacktrace -> {'EXIT', {__Reason, __Stacktrace}}
        end
     end)()
).

-endif.
