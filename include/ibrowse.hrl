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

-endif.
