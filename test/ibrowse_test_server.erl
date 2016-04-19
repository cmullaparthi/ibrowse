%%% File    : ibrowse_test_server.erl
%%% Author  : Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%% Description : A server to simulate various test scenarios
%%% Created : 17 Oct 2010 by Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>

-module(ibrowse_test_server).
-export([
         start_server/0,
         start_server/2,
         stop_server/1,
         get_conn_pipeline_depth/0
        ]).

-record(request, {method, uri, version, headers = [], body = [], state}).

-define(dec2hex(X), erlang:integer_to_list(X, 16)).
-define(ACCEPT_TIMEOUT_MS, 10000).
-define(CONN_PIPELINE_DEPTH, conn_pipeline_depth).

start_server() ->
    start_server(8181, tcp).

start_server(Port, Sock_type) ->
    Fun = fun() ->
		  Proc_name = server_proc_name(Port),
		  case whereis(Proc_name) of
		      undefined ->
			  register(Proc_name, self()),
			  ets:new(?CONN_PIPELINE_DEPTH, [named_table, public, set]),
			  case do_listen(Sock_type, Port, [{active, false},
							   {reuseaddr, true},
							   {nodelay, true},
							   {packet, http}]) of
			      {ok, Sock} ->
				  do_trace("Server listening on port: ~p~n", [Port]),
				  accept_loop(Sock, Sock_type);
			      Err ->
				  erlang:error(
				    lists:flatten(
				      io_lib:format(
					"Failed to start server on port ~p. ~p~n",
					[Port, Err]))),
				  exit({listen_error, Err})
			  end;
		      _X ->
			  ok
		  end
	  end,
    spawn_link(Fun),
    ibrowse_socks_server:start(8282, 0), %% No auth
    ibrowse_socks_server:start(8383, 2). %% Username/Password auth

stop_server(Port) ->
    catch server_proc_name(Port) ! stop,
    ibrowse_socks_server:stop(8282),
    ibrowse_socks_server:stop(8383),
    timer:sleep(2000),  % wait for server to receive msg and unregister
    ok.

get_conn_pipeline_depth() ->
    ets:tab2list(?CONN_PIPELINE_DEPTH).

server_proc_name(Port) ->
    list_to_atom("ibrowse_test_server_"++integer_to_list(Port)).

do_listen(tcp, Port, Opts) ->
    gen_tcp:listen(Port, Opts);
do_listen(ssl, Port, Opts) ->
    application:start(crypto),
    application:start(ssl),
    ssl:listen(Port, Opts).

do_accept(tcp, Listen_sock) ->
    gen_tcp:accept(Listen_sock, ?ACCEPT_TIMEOUT_MS);
do_accept(ssl, Listen_sock) ->
    ssl:ssl_accept(Listen_sock, ?ACCEPT_TIMEOUT_MS).

accept_loop(Sock, Sock_type) ->
    case do_accept(Sock_type, Sock) of
        {ok, Conn} ->
            Pid = spawn_link(fun() -> connection(Conn, Sock_type) end),
            set_controlling_process(Conn, Sock_type, Pid),
            accept_loop(Sock, Sock_type);
        {error, timeout} ->
            receive
                stop ->
                    ok
            after 10 ->
                accept_loop(Sock, Sock_type)
            end;
        Err ->
            Err
    end.

connection(Conn, Sock_type) ->
    catch ets:insert(?CONN_PIPELINE_DEPTH, {self(), 0}),
    try
	inet:setopts(Conn, [{packet, http}, {active, true}]),
        server_loop(Conn, Sock_type, #request{})
    after
        catch ets:delete(?CONN_PIPELINE_DEPTH, self())
    end.

set_controlling_process(Sock, tcp, Pid) ->
    gen_tcp:controlling_process(Sock, Pid);
set_controlling_process(Sock, ssl, Pid) ->
    ssl:controlling_process(Sock, Pid).

setopts(Sock, tcp, Opts) ->
    inet:setopts(Sock, Opts);
setopts(Sock, ssl, Opts) ->
    ssl:setopts(Sock, Opts).

server_loop(Sock, Sock_type, #request{headers = Headers} = Req) ->
    receive
        {http, Sock, {http_request, HttpMethod, HttpUri, HttpVersion}} ->
            catch ets:update_counter(?CONN_PIPELINE_DEPTH, self(), 1),
            server_loop(Sock, Sock_type, Req#request{method = HttpMethod,
                                                     uri = HttpUri,
                                                     version = HttpVersion});
        {http, Sock, {http_header, _, _, _, _} = H} ->
            server_loop(Sock, Sock_type, Req#request{headers = [H | Headers]});
        {http, Sock, http_eoh} ->
            case process_request(Sock, Sock_type, Req) of
                close_connection ->
                    gen_tcp:shutdown(Sock, read_write);
                not_done ->
                    ok;
		collect_body ->
		    server_loop(Sock, Sock_type, Req#request{state = collect_body});
                _ ->
                    catch ets:update_counter(?CONN_PIPELINE_DEPTH, self(), -1)
            end,
            server_loop(Sock, Sock_type, #request{});
        {http, Sock, {http_error, Packet}} when Req#request.state == collect_body ->
	    Req_1 = Req#request{body = list_to_binary([Packet, Req#request.body])},
	    case process_request(Sock, Sock_type, Req_1) of
		close_connection ->
                    gen_tcp:shutdown(Sock, read_write);
                ok ->
                    server_loop(Sock, Sock_type, #request{});
		collect_body ->
		    server_loop(Sock, Sock_type, Req_1)
	    end;	    
        {http, Sock, {http_error, Err}} ->
            io:format("Error parsing HTTP request:~n"
                      "Req so far : ~p~n"
                      "Err        : ~p", [Req, Err]),
            exit({http_error, Err});
        {setopts, Opts} ->
            setopts(Sock, Sock_type, Opts),
            server_loop(Sock, Sock_type, Req);
        {tcp_closed, Sock} ->
            do_trace("Client closed connection~n", []),
            ok;
        Other ->
            io:format("Recvd unknown msg: ~p~n", [Other]),
            exit({unknown_msg, Other})
    after 120000 ->
            do_trace("Timing out client connection~n", []),
            ok
    end.

do_trace(Fmt, Args) ->
    do_trace(get(my_trace_flag), Fmt, Args).

do_trace(true, Fmt, Args) ->
    io:format("~s -- " ++ Fmt, [ibrowse_lib:printable_date() | Args]);
do_trace(_, _, _) ->
    ok.

process_request(Sock, Sock_type,
                #request{method='GET',
                         headers = Headers,
                         uri = {abs_path, "/ibrowse_stream_once_chunk_pipeline_test"}} = Req) ->
    Req_id = case lists:keysearch("X-Ibrowse-Request-Id", 3, Headers) of
                 false ->
                     "";
                 {value, {http_header, _, _, _, Req_id_1}} ->
                     Req_id_1
             end,
    Req_id_header = ["x-ibrowse-request-id: ", Req_id, "\r\n"],
    do_trace("Recvd req: ~p~n", [Req]),
    Body = string:join([integer_to_list(X) || X <- lists:seq(1,100)], "-"),
    Chunked_body = chunk_request_body(Body, 50),
    Resp_1 = [<<"HTTP/1.1 200 OK\r\n">>,
              Req_id_header,
              <<"Transfer-Encoding: chunked\r\n\r\n">>],
    Resp_2 = Chunked_body,
    do_send(Sock, Sock_type, Resp_1),
    timer:sleep(100),
    do_send(Sock, Sock_type, Resp_2);
process_request(Sock, Sock_type,
                #request{method='GET',
                         headers = _Headers,
                         uri = {abs_path, "/ibrowse_inac_timeout_test"}} = Req) ->
    do_trace("Recvd req: ~p. Sleeping for 30 secs...~n", [Req]),
    timer:sleep(3000),
    do_trace("...Sending response now.~n", []),
    Resp = <<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n">>,
    do_send(Sock, Sock_type, Resp);
process_request(Sock, Sock_type,
                #request{method='HEAD',
                         headers = _Headers,
                         uri = {abs_path, "/ibrowse_head_transfer_enc"}}) ->
    Resp = <<"HTTP/1.1 400 Bad Request\r\nServer: Apache-Coyote/1.1\r\nContent-Length:5\r\nDate: Wed, 04 Apr 2012 16:53:49 GMT\r\n\r\nabcde">>,
    do_send(Sock, Sock_type, Resp);
process_request(Sock, Sock_type,
                #request{method='POST',
                         headers = Headers,
                         uri = {abs_path, "/echo_body"},
			body = Body}) ->
    Content_len = get_content_length(Headers),
    case iolist_size(Body) == Content_len of
	true ->
	    Resp = [<<"HTTP/1.1 200 OK\r\nContent-Length: ">>, integer_to_list(Content_len), <<"\r\nServer: ibrowse_test_server\r\n\r\n">>, Body],
	    do_send(Sock, Sock_type, list_to_binary(Resp));
	false ->
	    collect_body
    end;
process_request(Sock, Sock_type,
                #request{method='GET',
                         headers = Headers,
                         uri = {abs_path, "/ibrowse_echo_header"}}) ->
    Tag = "x-binary",
    Headers_1 = [{to_lower(X), to_lower(Y)} || {http_header, _, X, _, Y} <- Headers],
    X_binary_header_val = case lists:keysearch(Tag, 1, Headers_1) of
                              false ->
                                  "not_found";
                              {value, {_, V}} ->
                                  V
                          end,
    Resp = [<<"HTTP/1.1 200 OK\r\n">>,
            <<"Server: ibrowse_test\r\n">>,
            Tag, ": ", X_binary_header_val, "\r\n",
            <<"Content-Length: 0\r\n\r\n">>],
    do_send(Sock, Sock_type, Resp);

process_request(Sock, Sock_type,
                #request{method='HEAD',
                         headers = _Headers,
                         uri = {abs_path, "/ibrowse_head_test"}}) ->
    Resp = <<"HTTP/1.1 200 OK\r\nServer: Apache-Coyote/1.1\r\Date: Wed, 04 Apr 2012 16:53:49 GMT\r\nConnection: close\r\n\r\n">>,
    do_send(Sock, Sock_type, Resp);
process_request(Sock, Sock_type,
                #request{method='POST',
                         headers = _Headers,
                         uri = {abs_path, "/ibrowse_303_no_body_test"}}) ->
    Resp = <<"HTTP/1.1 303 See Other\r\nLocation: http://example.org\r\n\r\n">>,
    do_send(Sock, Sock_type, Resp);
process_request(Sock, Sock_type,
                #request{method='POST',
                         headers = _Headers,
                         uri = {abs_path, "/ibrowse_303_with_body_test"}}) ->
    Resp = <<"HTTP/1.1 303 See Other\r\nLocation: http://example.org\r\nContent-Length: 5\r\n\r\nabcde">>,
    do_send(Sock, Sock_type, Resp);
process_request(Sock, Sock_type,
                #request{method='GET',
                         headers = _Headers,
                         uri = {abs_path, "/ibrowse_preserve_status_line"}}) ->
    Resp = <<"HTTP/1.1 200 OKBlah\r\nContent-Length: 5\r\n\r\nabcde">>,
    do_send(Sock, Sock_type, Resp);
process_request(Sock, Sock_type,
    #request{method='GET',
        headers = _Headers,
        uri = {abs_path, "/ibrowse_handle_one_request_only_with_delay"}}) ->
    timer:sleep(2000),
    Resp = <<"HTTP/1.1 200 OK\r\nServer: Apache-Coyote/1.1\r\nDate: Wed, 04 Apr 2012 16:53:49 GMT\r\nConnection: close\r\n\r\n">>,
    do_send(Sock, Sock_type, Resp),
    close_connection;
process_request(Sock, Sock_type,
    #request{method='GET',
        headers = _Headers,
        uri = {abs_path, "/ibrowse_handle_one_request_only"}}) ->
    Resp = <<"HTTP/1.1 200 OK\r\nServer: Apache-Coyote/1.1\r\nDate: Wed, 04 Apr 2012 16:53:49 GMT\r\nConnection: close\r\n\r\n">>,
    do_send(Sock, Sock_type, Resp),
    close_connection;
process_request(Sock, Sock_type,
    #request{method='GET',
        headers = _Headers,
        uri = {abs_path, "/ibrowse_send_file_conn_close"}}) ->
    Resp = <<"HTTP/1.1 200 OK\r\nServer: Apache-Coyote/1.1\r\nDate: Wed, 04 Apr 2012 16:53:49 GMT\r\nConnection: close\r\n\r\nblahblah-">>,    
    do_send(Sock, Sock_type, Resp),
    timer:sleep(1000),
    do_send(Sock, Sock_type, <<"blahblah">>),
    close_connection;
process_request(_Sock, _Sock_type, #request{uri = {abs_path, "/never_respond"} } ) ->
    not_done;
process_request(Sock, Sock_type, Req) ->
    do_trace("Recvd req: ~p~n", [Req]),
    Resp = <<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n">>,
    do_send(Sock, Sock_type, Resp),
    timer:sleep(random:uniform(100)).

do_send(Sock, tcp, Resp) ->
    gen_tcp:send(Sock, Resp);
do_send(Sock, ssl, Resp) ->
    ssl:send(Sock, Resp).

%%------------------------------------------------------------------------------
%% Utility functions
%%------------------------------------------------------------------------------

chunk_request_body(Body, _ChunkSize) when is_tuple(Body) orelse
                                          is_function(Body) ->
    Body;
chunk_request_body(Body, ChunkSize) ->
    chunk_request_body(Body, ChunkSize, []).

chunk_request_body(Body, _ChunkSize, Acc) when Body == <<>>; Body == [] ->
    LastChunk = "0\r\n",
    lists:reverse(["\r\n", LastChunk | Acc]);
chunk_request_body(Body, ChunkSize, Acc) when is_binary(Body),
                                              size(Body) >= ChunkSize ->
    <<ChunkBody:ChunkSize/binary, Rest/binary>> = Body,
    Chunk = [?dec2hex(ChunkSize),"\r\n",
             ChunkBody, "\r\n"],
    chunk_request_body(Rest, ChunkSize, [Chunk | Acc]);
chunk_request_body(Body, _ChunkSize, Acc) when is_binary(Body) ->
    BodySize = size(Body),
    Chunk = [?dec2hex(BodySize),"\r\n",
             Body, "\r\n"],
    LastChunk = "0\r\n",
    lists:reverse(["\r\n", LastChunk, Chunk | Acc]);
chunk_request_body(Body, ChunkSize, Acc) when length(Body) >= ChunkSize ->
    {ChunkBody, Rest} = split_list_at(Body, ChunkSize),
    Chunk = [?dec2hex(ChunkSize),"\r\n",
             ChunkBody, "\r\n"],
    chunk_request_body(Rest, ChunkSize, [Chunk | Acc]);
chunk_request_body(Body, _ChunkSize, Acc) when is_list(Body) ->
    BodySize = length(Body),
    Chunk = [?dec2hex(BodySize),"\r\n",
             Body, "\r\n"],
    LastChunk = "0\r\n",
    lists:reverse(["\r\n", LastChunk, Chunk | Acc]).

split_list_at(List, N) ->
    split_list_at(List, N, []).

split_list_at([], _, Acc) ->
    {lists:reverse(Acc), []};
split_list_at(List2, 0, List1) ->
    {lists:reverse(List1), List2};
split_list_at([H | List2], N, List1) ->
    split_list_at(List2, N-1, [H | List1]).

to_lower(X) when is_atom(X) ->
    list_to_atom(to_lower(atom_to_list(X)));
to_lower(X) when is_list(X) ->
    string:to_lower(X).

get_content_length([{http_header, _, 'Content-Length', _, V} | _]) ->
    list_to_integer(V);
get_content_length([{http_header, _, _X, _, _Y} | T]) ->
    get_content_length(T);
get_content_length([]) ->
    undefined.
