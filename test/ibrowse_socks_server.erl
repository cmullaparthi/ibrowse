%%%-------------------------------------------------------------------
%%% @author Chandru Mullaparthi <>
%%% @copyright (C) 2016, Chandru Mullaparthi
%%% @doc
%%%
%%% @end
%%% Created : 19 Apr 2016 by Chandru Mullaparthi <>
%%%-------------------------------------------------------------------
-module(ibrowse_socks_server).

-behaviour(gen_server).

%% API
-export([start/2, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {listen_port, listen_socket, auth_method}).

-define(NO_AUTH, 0).
-define(AUTH_USER_PW, 2).

%%%===================================================================
%%% API
%%%===================================================================

start(Port, Auth_method) ->
    Name = make_proc_name(Port),
    gen_server:start({local, Name}, ?MODULE, [Port, Auth_method], []).

stop(Port) ->
    make_proc_name(Port) ! stop.

make_proc_name(Port) ->
    list_to_atom("ibrowse_socks_server_" ++ integer_to_list(Port)).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Port, Auth_method]) ->
    State = #state{listen_port = Port, auth_method = Auth_method},
    {ok, Sock} = gen_tcp:listen(State#state.listen_port, [{active, false}, binary, {reuseaddr, true}]),
    self() ! accept_connection,
    process_flag(trap_exit, true),
    {ok, State#state{listen_socket = Sock}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(accept_connection, State) ->
    case gen_tcp:accept(State#state.listen_socket, 1000) of
        {error, timeout} ->
            self() ! accept_connection,
            {noreply, State};
        {ok, Socket} ->
            Pid = proc_lib:spawn_link(fun() ->
                                              socks_server_loop(Socket, State#state.auth_method)
                                      end),
            gen_tcp:controlling_process(Socket, Pid),
            Pid ! ready,
            self() ! accept_connection,
            {noreply, State};
        _Err ->
            {stop, normal, State}
    end;

handle_info(stop, State) ->
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
socks_server_loop(In_socket, Auth_method) ->
    receive
        ready ->
            socks_server_loop(In_socket, Auth_method, <<>>, unauth)
    end.

socks_server_loop(In_socket, Auth_method, Acc, unauth) ->
    inet:setopts(In_socket, [{active, once}]),
    receive
        {tcp, In_socket, Data} ->
            Acc_1 = list_to_binary([Acc, Data]),
            case Acc_1 of
                <<5, ?NO_AUTH>> when Auth_method == ?NO_AUTH ->
                    ok = gen_tcp:send(In_socket, <<5, ?NO_AUTH>>),
                    socks_server_loop(In_socket, Auth_method, <<>>, auth_done);
                <<5, Num_auth_methods, Auth_methods:Num_auth_methods/binary>> ->
                    case lists:member(Auth_method, binary_to_list(Auth_methods)) of
                        true ->
                            ok = gen_tcp:send(In_socket, <<5, Auth_method>>),
                            Conn_state = case Auth_method of
                                             ?NO_AUTH -> auth_done;
                                             _ -> auth_pending
                                         end,
                            socks_server_loop(In_socket, Auth_method, <<>>, Conn_state);
                        false ->
                            ok = gen_tcp:send(In_socket, <<5, 16#ff>>),
                            gen_tcp:close(In_socket)
                    end;
                _ ->
                    ok = gen_tcp:send(In_socket, <<5, 0>>),
                    gen_tcp:close(In_socket)
            end;
        {tcp_closed, In_socket} ->
            ok;
        {tcp_error, In_socket, _Rsn} ->
            ok
    end;
socks_server_loop(In_socket, Auth_method, Acc, auth_pending) ->
    inet:setopts(In_socket, [{active, once}]),
    receive
        {tcp, In_socket, Data} ->
            Acc_1 = list_to_binary([Acc, Data]),
            case Acc_1 of
                <<1, U_len, Username:U_len/binary, P_len, Password:P_len/binary>> ->
                    case check_user_pw(Username, Password) of
                        ok ->
                            ok = gen_tcp:send(In_socket, <<1, 0>>),
                            socks_server_loop(In_socket, Auth_method, <<>>, auth_done);
                        notok ->
                            ok = gen_tcp:send(In_socket, <<1, 1>>),
                            gen_tcp:close(In_socket)
                    end;
                _ ->
                    socks_server_loop(In_socket, Auth_method, Acc_1, auth_pending)
            end;
        {tcp_closed, In_socket} ->
            ok;
        {tcp_error, In_socket, _Rsn} ->
            ok
    end;
socks_server_loop(In_socket, Auth_method, Acc, auth_done) ->
    inet:setopts(In_socket, [{active, once}]),
    receive
        {tcp, In_socket, Data} ->
            Acc_1 = list_to_binary([Acc, Data]),
            case Acc_1 of
                <<5, 1, 0, Addr_type, Dest_ip:4/binary, Dest_port:16>> when Addr_type == 1->
                    handle_connect(In_socket, Addr_type, Dest_ip, Dest_port);
                <<5, 1, 0, Addr_type, Dest_len, Dest_hostname:Dest_len/binary, Dest_port:16>> when Addr_type == 3 ->
                    handle_connect(In_socket, Addr_type, Dest_hostname, Dest_port);
                <<5, 1, 0, Addr_type, Dest_ip:16/binary, Dest_port:16>> when Addr_type == 4->
                    handle_connect(In_socket, Addr_type, Dest_ip, Dest_port);
                _ ->
                    socks_server_loop(In_socket, Auth_method, Acc_1, auth_done)
            end;
        {tcp_closed, In_socket} ->
            ok;
        {tcp_error, In_socket, _Rsn} ->
            ok
    end.

handle_connect(In_socket, Addr_type, Dest_host, Dest_port) ->
    Dest_host_1 = case Addr_type of
                      1 ->
                          list_to_tuple(binary_to_list(Dest_host));
                      3 ->
                          binary_to_list(Dest_host);
                      4 ->
                          list_to_tuple(binary_to_list(Dest_host))
                  end,
    case gen_tcp:connect(Dest_host_1, Dest_port, [binary, {active, once}]) of
        {ok, Out_socket} ->
            Addr = case Addr_type of
                       1 ->
                           <<Dest_host/binary, Dest_port:16>>;
                       3 ->
                           Len = size(Dest_host),
                           <<Len, Dest_host/binary, Dest_port:16>>;
                       4 ->
                           <<Dest_host/binary, Dest_port:16>>
                   end,
            ok = gen_tcp:send(In_socket, <<5, 0, 0, Addr_type, Addr/binary>>),
            inet:setopts(In_socket, [{active, once}]),
            inet:setopts(Out_socket, [{active, once}]),
            connected_loop(In_socket, Out_socket);
        _Err ->
            ok = gen_tcp:send(<<5, 1>>),
            gen_tcp:close(In_socket)
    end.

check_user_pw(<<"user">>, <<"password">>) ->
    ok;
check_user_pw(_, _) ->
    notok.

connected_loop(In_socket, Out_socket) ->
    receive
        {tcp, In_socket, Data} ->
            inet:setopts(In_socket, [{active, once}]),
            ok = gen_tcp:send(Out_socket, Data),
            connected_loop(In_socket, Out_socket);
        {tcp, Out_socket, Data} ->
            inet:setopts(Out_socket, [{active, once}]),
            ok = gen_tcp:send(In_socket, Data),
            connected_loop(In_socket, Out_socket);
        _ ->
            ok
    end.
