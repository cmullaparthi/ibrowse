%%%-------------------------------------------------------------------
%%% File    : ibrowse.erl
%%% Author  : Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%% Description : Load balancer process for HTTP client connections.
%%%
%%% Created : 11 Oct 2003 by Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%%-------------------------------------------------------------------
%% @author Chandrashekhar Mullaparthi <chandrashekhar dot mullaparthi at gmail dot com>
%% @copyright 2005-2007 Chandrashekhar Mullaparthi
%% @version 1.2.7
%% @doc The ibrowse application implements an HTTP 1.1 client. This
%% module implements the API of the HTTP client. There is one named
%% process called 'ibrowse' which acts as a load balancer. There is
%% one process to handle one TCP connection to a webserver
%% (implemented in the module ibrowse_http_client). Multiple connections to a
%% webserver are setup based on the settings for each webserver. The
%% ibrowse process also determines which connection to pipeline a
%% certain request on.  The functions to call are send_req/3,
%% send_req/4, send_req/5, send_req/6.
%%
%% <p>Here are a few sample invocations.</p>
%%
%% <code>
%% ibrowse:send_req("http://intranet/messenger/", [], get). 
%% <br/><br/>
%% 
%% ibrowse:send_req("http://www.google.com/", [], get, [], 
%% 		 [{proxy_user, "XXXXX"},
%% 		  {proxy_password, "XXXXX"},
%% 		  {proxy_host, "proxy"},
%% 		  {proxy_port, 8080}], 1000). 
%% <br/><br/>
%%
%%ibrowse:send_req("http://www.erlang.org/download/otp_src_R10B-3.tar.gz", [], get, [],
%% 		 [{proxy_user, "XXXXX"},
%% 		  {proxy_password, "XXXXX"},
%% 		  {proxy_host, "proxy"},
%% 		  {proxy_port, 8080},
%% 		  {save_response_to_file, true}], 1000).
%% <br/><br/>
%%
%% ibrowse:set_dest("www.hotmail.com", 80, [{max_sessions, 10},
%% 					    {max_pipeline_size, 1}]).
%% <br/><br/>
%%
%% ibrowse:send_req("http://www.erlang.org", [], head).
%%
%% <br/><br/>
%% ibrowse:send_req("http://www.sun.com", [], options).
%%
%% <br/><br/>
%% ibrowse:send_req("http://www.bbc.co.uk", [], trace).
%%
%% <br/><br/>
%% ibrowse:send_req("http://www.google.com", [], get, [], 
%%                   [{stream_to, self()}]).
%% </code>
%%
%% <p>A driver exists which implements URL encoding in C, but the
%% speed achieved using only erlang has been good enough, so the
%% driver isn't actually used.</p>

-module(ibrowse).
-vsn('$Id: ibrowse.erl,v 1.5 2008/02/07 12:02:13 chandrusf Exp $ ').

-behaviour(gen_server).
%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% External exports
-export([start_link/0, start/0, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% API interface
-export([send_req/3,
	 send_req/4,
	 send_req/5,
	 send_req/6,
	 trace_on/0,
	 trace_off/0,
	 trace_on/2,
	 trace_off/2,
	 set_dest/3]).

%% Internal exports
-export([reply/2,
	 finished_async_request/0,
	 shutting_down/0]).

-ifdef(debug).
-compile(export_all).
-endif.

-import(ibrowse_http_client, [parse_url/1,
			      printable_date/0]).

-record(state, {dests=[], trace=false, port}).

-include("ibrowse.hrl").

-define(DEF_MAX_SESSIONS,10).
-define(DEF_MAX_PIPELINE_SIZE,10).

%% key = {Host, Port} where Host is a string, or {Name, Host, Port} 
%% where Name is an atom.
%% conns = queue()
-record(dest, {key,
	       conns=queue:new(),
	       num_sessions=0,
	       max_sessions=?DEF_MAX_SESSIONS, 
	       max_pipeline_size=?DEF_MAX_PIPELINE_SIZE,
	       options=[],
	       trace=false}).

%%====================================================================
%% External functions
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], [{debug, []}]).

stop() ->
    catch gen_server:call(ibrowse, stop).

%% @doc Sets options for a destination. If the options have not been
%% set in the ibrowse.conf file, it can be set using this function
%% before sending the first request to the destination. If not,
%% defaults will be used. Entries in ibrowse.conf look like this.
%% <code><br/>
%% {dest, Host, Port, MaxSess, MaxPipe, Options}.<br/>
%% where <br/>
%% Host = string(). "www.erlang.org" | "193.180.168.23"<br/>
%% Port = integer()<br/>
%% MaxSess = integer()<br/>
%% MaxPipe = integer()<br/>
%% Options = optionList() -- see options in send_req/5<br/>
%% </code>
%% @spec set_dest(Host::string(),Port::integer(),Opts::opt_list()) -> ok
%% opt_list() = [opt]
%% opt() = {max_sessions, integer()}          | 
%%         {max_pipeline_size, integer()}     |
%%         {trace, boolean()}
set_dest(Host,Port,Opts) ->
    gen_server:call(?MODULE,{set_dest,Host,Port,Opts}).

%% @doc This is the basic function to send a HTTP request.
%% The Status return value indicates the HTTP status code returned by the webserver
%% @spec send_req(Url::string(), Headers::headerList(), Method::method()) -> response()
%% headerList() = [{header(), value()}]
%% header() = atom() | string()
%% value() = term()
%% method() = get | post | head | options | put | delete | trace | mkcol | propfind | proppatch | lock | unlock | move | copy
%% Status = string()
%% ResponseHeaders = [respHeader()]
%% respHeader() = {headerName(), headerValue()}
%% headerName() = string()
%% headerValue() = string()
%% response() = {ok, Status, ResponseHeaders, ResponseBody} | {error, Reason}
%% ResponseBody = string() | {file, Filename}
%% Reason = term()
send_req(Url, Headers, Method) ->
    send_req(Url, Headers, Method, [], []).

%% @doc Same as send_req/3. 
%% If a list is specified for the body it has to be a flat list.
%% @spec send_req(Url, Headers, Method::method(), Body::body()) -> response()
%% body() = [] | string() | binary()
send_req(Url, Headers, Method, Body) ->
    send_req(Url, Headers, Method, Body, []).

%% @doc Same as send_req/4. 
%% For a description of SSL Options, look in the ssl manpage. If the
%% HTTP Version to use is not specified, the default is 1.1.
%% <br/>
%% <p>The <code>host_header</code> is useful in the case where ibrowse is
%% connecting to a component such as <a
%% href="http://www.stunnel.org">stunnel</a> which then sets up a
%% secure connection to a webserver. In this case, the URL supplied to
%% ibrowse must have the stunnel host/port details, but that won't
%% make sense to the destination webserver. This option can then be
%% used to specify what should go in the <code>Host</code> header in
%% the request.</p>
%% <ul>
%% <li>When both the options <code>save_response_to_file</code> and <code>stream_to</code> 
%% are specified, the former takes precedence.</li>
%%
%% <li>For the <code>save_response_to_file</code> option, the response body is saved to
%% file only if the status code is in the 200-299 range. If not, the response body is returned
%% as a string.</li>
%% <li>Whenever an error occurs in the processing of a request, ibrowse will return as much
%% information as it has, such as HTTP Status Code and HTTP Headers. When this happens, the response
%% is of the form <code>{error, {Reason, {stat_code, StatusCode}, HTTP_headers}}</code></li>
%% </ul>
%% @spec send_req(Url::string(), Headers::headerList(), Method::method(), Body::body(), Options::optionList()) -> response()
%% optionList() = [option()]
%% option() = {max_sessions, integer()}        |
%%          {max_pipeline_size, integer()}     |
%%          {trace, boolean()}                 | 
%%          {is_ssl, boolean()}                |
%%          {ssl_options, [SSLOpt]}            |
%%          {pool_name, atom()}                |
%%          {proxy_host, string()}             |
%%          {proxy_port, integer()}            |
%%          {proxy_user, string()}             |
%%          {proxy_password, string()}         |
%%          {use_absolute_uri, boolean()}      |
%%          {basic_auth, {username(), password()}} |
%%          {cookie, string()}                 |
%%          {content_length, integer()}        |
%%          {content_type, string()}           |
%%          {save_response_to_file, srtf()}    |
%%          {stream_to, process()}             |
%%          {http_vsn, {MajorVsn, MinorVsn}}   |
%%          {host_header, string()}            |
%%          {transfer_encoding, {chunked, ChunkSize}}
%% 
%% process() = pid() | atom()
%% username() = string()
%% password() = string()
%% SSLOpt = term()
%% ChunkSize = integer()
%% srtf() = boolean() | filename()
%% filename() = string()
%% 
send_req(Url, Headers, Method, Body, Options) ->
    send_req(Url, Headers, Method, Body, Options, 30000).

%% @doc Same as send_req/5. 
%% All timeout values are in milliseconds.
%% @spec send_req(Url, Headers::headerList(), Method::method(), Body::body(), Options::optionList(), Timeout) -> response()
%% Timeout = integer() | infinity
send_req(Url, Headers, Method, Body, Options, Timeout) ->
    Timeout_1 = case Timeout of
		    infinity ->
			infinity;
		    _ ->
			Timeout + 1000
		end,
    case catch gen_server:call(ibrowse,
			       {send_req, [Url, Headers, Method,
					   Body, Options, Timeout]},
			       Timeout_1) of
	{'EXIT', {timeout, _}} ->
	    {error, genserver_timedout};
	Res ->
	    Res
    end.

%% @doc Turn tracing on for the ibrowse process
trace_on() ->
    ibrowse ! {trace, true}.
%% @doc Turn tracing off for the ibrowse process
trace_off() ->
    ibrowse ! {trace, false}.

%% @doc Turn tracing on for all connections to the specified HTTP
%% server. Host is whatever is specified as the domain name in the URL
%% @spec trace_on(Host, Port) -> term() 
%% Host = string() 
%% Port = integer()
trace_on(Host, Port) ->
    ibrowse ! {trace, true, Host, Port}.

%% @doc Turn tracing OFF for all connections to the specified HTTP
%% server.
%% @spec trace_off(Host, Port) -> term()
trace_off(Host, Port) ->
    ibrowse ! {trace, false, Host, Port}.

%% @doc Internal export. Called by a HTTP connection process to
%% indicate to the load balancing process (ibrowse) that a synchronous
%% request has finished processing.
reply(OrigCaller, Reply) ->
    gen_server:call(ibrowse, {reply, OrigCaller, Reply, self()}).

%% @doc Internal export. Called by a HTTP connection process to
%% indicate to the load balancing process (ibrowse) that an
%% asynchronous request has finished processing.
finished_async_request() ->
    gen_server:call(ibrowse, {finished_async_request, self()}).

%% @doc Internal export. Called by a HTTP connection process to
%% indicate to ibrowse that it is shutting down and further requests
%% should not be sent it's way.
shutting_down() ->
    gen_server:call(ibrowse, {shutting_down, self()}).

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init(_) ->
    process_flag(trap_exit, true),
    State = #state{},
    put(my_trace_flag, State#state.trace),
    case code:priv_dir(ibrowse) of
	{error, _} ->
	    {ok, #state{}};
	PrivDir ->
	    Filename = filename:join(PrivDir, "ibrowse.conf"),
	    case file:consult(Filename) of
		{ok, Terms} ->
		    Fun = fun({dest, Host, Port, MaxSess, MaxPipe, Options}, Acc) 
			     when list(Host), integer(Port),
			     integer(MaxSess), MaxSess > 0,
			     integer(MaxPipe), MaxPipe > 0, list(Options) ->
				  Key = maybe_named_key(Host, Port, Options),
				  NewDest = #dest{key=Key,
						  options=Options,
						  max_sessions=MaxSess,
						  max_pipeline_size=MaxPipe},
				  [NewDest | Acc];
			     (_, Acc) ->
				  Acc
			  end,
		    {ok, #state{dests=lists:foldl(Fun, [], Terms)}};
		_Else ->
		    {ok, #state{}}
	    end
    end.

%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({send_req, _}=Req, From, State) ->
    State_1 = handle_send_req(Req, From, State),
    {noreply, State_1};
		    
handle_call({reply, OrigCaller, Reply, HttpClientPid}, From, State) ->
    gen_server:reply(From, ok),
    gen_server:reply(OrigCaller, Reply),
    Key = {HttpClientPid, pending_reqs},
    case get(Key) of
        NumPend when integer(NumPend) ->
            put(Key, NumPend - 1);
        _ ->
            ok
    end,
    {noreply, State};

handle_call({finished_async_request, HttpClientPid}, From, State) ->
    gen_server:reply(From, ok),
    Key = {HttpClientPid, pending_reqs},
    case get(Key) of
        NumPend when integer(NumPend) ->
            put(Key, NumPend - 1);
        _ ->
            ok
    end,
    {noreply, State};

handle_call({shutting_down, Pid}, _From, State) ->
    State_1 = handle_conn_closing(Pid, State),
    {reply, ok, State_1};
    
handle_call({set_dest,Host,Port,Opts}, _From, State) ->
    State2 = set_destI(State,Host,Port,Opts),
    {reply, ok, State2};

handle_call(stop, _From, State) ->
    {stop, shutting_down, ok, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
%% A bit of a bodge here...ideally, would be good to store connection state 
%% in the queue itself against each Pid.
handle_info({done_req, Pid}, State) ->
    Key = {Pid, pending_reqs},
    case get(Key) of
	NumPend when integer(NumPend) ->
	    put(Key, NumPend - 1);
	_ ->
	    ok
    end,
    do_trace("~p has finished a request~n", [Pid]),
    {noreply, State};

handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};

handle_info({'EXIT', Pid, _Reason}, State) ->
    %% TODO: We have to reply to all the pending requests
    State_1 = handle_conn_closing(Pid, State),
    do_trace("~p has exited~n", [Pid]),
    {noreply, State_1};
	
handle_info({shutting_down, Pid}, State) ->
    State_1 = handle_conn_closing(Pid, State),
    {noreply, State_1};

handle_info({conn_closing, Pid, OriReq, From}, State) ->
    State_1 = handle_conn_closing(Pid, State),
    State_2 = handle_send_req(OriReq, From, State_1),
    {noreply, State_2};

handle_info({trace, Bool}, State) ->
    put(my_trace_flag, Bool),
    {noreply, State#state{trace=Bool}};

handle_info({trace, Bool, Host, Port}, #state{dests=Dests}=State) ->
    case lists:keysearch({Host, Port}, #dest.key, Dests) of
	{value, Dest} ->
	    lists:foreach(fun(ConnPid) ->
				  ConnPid ! {trace, Bool}
			  end, queue:to_list(Dest#dest.conns)),
	    {noreply, State#state{dests=lists:keyreplace({Host,Port}, #dest.key, Dests, Dest#dest{trace=Bool})}};
	false ->
	    do_trace("Not found any state information for specified Host, Port.~n", []),
	    {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

handle_send_req({send_req, [Url, _Headers, _Method, _Body, Options, _Timeout]}=Req,
		From, State) ->
    case get_host_port(Url, Options) of
	{Host, Port, _RelPath} ->
	    Key = maybe_named_key(Host, Port, Options),
	    case lists:keysearch(Key, #dest.key, State#state.dests) of
		false ->
		    {ok, Pid} = spawn_new_connection(Key, false, Options),
		    Pid ! {Req, From},
		    Q = queue:new(),
		    Q_1 = queue:in(Pid, Q),
		    NewDest = #dest{key=Key,conns=Q_1,num_sessions=1}, %% MISSING is_ssl
		    State#state{dests=[NewDest|State#state.dests]};
		{value, #dest{conns=Conns,
			      num_sessions=NumS,
			      max_pipeline_size=MaxPSz,
			      max_sessions=MaxS}=Dest} ->
		    case get_free_worker(Conns, NumS, MaxS, MaxPSz) of
			spawn_new_connection ->
			    do_trace("Spawning new connection~n", []),
			    {ok, Pid} = spawn_new_connection(Key, Dest#dest.trace, Dest#dest.options),
			    Pid ! {Req, From},
			    Q_1 = queue:in(Pid, Conns),
			    Dest_1 = Dest#dest{conns=Q_1, num_sessions=NumS+1},
			    State#state{dests=lists:keyreplace(Key, #dest.key, State#state.dests, Dest_1)};
			not_found ->
			    do_trace("State -> ~p~nPDict -> ~p~n", [State, get()]),
			    gen_server:reply(From, {error, retry_later}), 
			    State;
			{ok, Pid, _, ConnPids} ->
			    do_trace("Reusing existing pid: ~p~n", [Pid]),
			    Pid_key = {Pid, pending_reqs},
			    put(Pid_key, get(Pid_key) + 1),
			    Pid ! {Req, From},
			    State#state{dests=lists:keyreplace(Key, #dest.key, State#state.dests,Dest#dest{conns=ConnPids})}
		    end
	    end;
	invalid_uri ->
	    gen_server:reply(From, {error, invalid_uri}), 
	    State
    end.

get_host_port(Url, Options) ->
    case get_value(proxy_host, Options, false) of
	false ->
	    case parse_url(Url) of
		#url{host=H, port=P, path=Path} ->
		    {H, P, Path};
		_Err ->
		    invalid_uri
	    end;
	PxyHost ->
	    PxyPort = get_value(proxy_port, Options, 80),
	    {PxyHost, PxyPort, Url}
    end.

handle_conn_closing(Pid, #state{dests=Dests}=State) ->
    erase({Pid, pending_reqs}),
    HostKey = get({Pid, hostport}),
    erase({Pid, hostport}),
    do_trace("~p is shutting down~n", [Pid]),
    case lists:keysearch(HostKey, #dest.key, Dests) of
	{value, #dest{num_sessions=Num, conns=Q}=Dest} ->
	    State#state{dests=lists:keyreplace(HostKey, #dest.key, Dests, 
					       Dest#dest{conns=del_from_q(Q, Num, Pid), num_sessions=Num-1})};
	false ->
	    State
    end.

%% Replaces destination information if found, otherwise appends it.
%% Copies over Connection Queue and Number of sessions.
set_destI(State,Host,Port,Opts) ->
    #state{dests=DestList} = State,
    Key = maybe_named_key(Host, Port, Opts),
    NewDests = case lists:keysearch(Key, #dest.key, DestList) of
		   false ->
		       Dest = insert_opts(Opts,#dest{key=Key}),
		       [Dest | DestList];
		   {value, OldDest} ->
		       OldDest_1 = insert_opts(Opts, OldDest),
		       [OldDest_1 | (DestList -- [OldDest])]
	       end,
    State#state{dests=NewDests}.

insert_opts(Opts, Dest) ->
    insert_opts_1(Opts, Dest#dest{options=Opts}).

insert_opts_1([],Dest) -> Dest;
insert_opts_1([{max_sessions,Msess}|T],Dest) ->
    insert_opts_1(T,Dest#dest{max_sessions=Msess});
insert_opts_1([{max_pipeline_size,Mpls}|T],Dest) ->
    insert_opts_1(T,Dest#dest{max_pipeline_size=Mpls});
insert_opts_1([{trace,Bool}|T],Dest) when Bool==true; Bool==false ->
    insert_opts_1(T,Dest#dest{trace=Bool});
insert_opts_1([_|T],Dest) -> %% ignores other
    insert_opts_1(T,Dest).

% Picks out the worker with the minimum pipeline size
% If a worker is found with a non-zero pipeline size, but the number of sessins
% is less than the max allowed sessions, a new connection is spawned.
get_free_worker(Q, NumSessions, MaxSessions, MaxPSz) ->
    case get_free_worker_1(Q, NumSessions, MaxPSz, {undefined, undefined}) of
	not_found when NumSessions < MaxSessions ->
	    spawn_new_connection;
	not_found ->
	    not_found;
	{ok, Pid, PSz, _Q1} when NumSessions < MaxSessions, PSz > 0 ->
	    do_trace("Found Pid -> ~p. PSz -> ~p~n", [Pid, PSz]),
	    spawn_new_connection;
	Ret ->
	    do_trace("get_free_worker: Ret -> ~p~n", [Ret]),
	    Ret
    end.

get_free_worker_1(_, 0, _, {undefined, undefined}) ->
    not_found;
get_free_worker_1({{value, WorkerPid}, Q}, 0, _, {MinPSzPid, PSz}) ->
    {ok, MinPSzPid, PSz, queue:in(WorkerPid, Q)};
get_free_worker_1({{value, Pid}, Q1}, NumSessions, MaxPSz, {_MinPSzPid, MinPSz}=V) ->
    do_trace("Pid -> ~p. MaxPSz -> ~p MinPSz -> ~p~n", [Pid, MaxPSz, MinPSz]),
    case get({Pid, pending_reqs}) of
	NumP when NumP < MaxPSz, NumP < MinPSz ->
	    get_free_worker_1(queue:out(queue:in(Pid, Q1)), NumSessions-1, MaxPSz, {Pid, NumP});
	_ ->
	    get_free_worker_1(queue:out(queue:in(Pid, Q1)), NumSessions-1, MaxPSz, V)
    end;
get_free_worker_1({empty, _Q}, _, _, _) ->
    do_trace("Queue empty -> not_found~n", []),
    not_found;
get_free_worker_1(Q, NumSessions, MaxPSz, MinPSz) ->
    get_free_worker_1(queue:out(Q), NumSessions, MaxPSz, MinPSz).

spawn_new_connection({_Pool_name, Host, Port}, Trace, Options) ->
    spawn_new_connection({Host, Port}, Trace, Options);
spawn_new_connection({Host, Port}, Trace, Options) ->
    {ok, Pid} = ibrowse_http_client:start_link([Host, Port, Trace, Options]),
    Key = maybe_named_key(Host, Port, Options),
    put({Pid, pending_reqs}, 1),
    put({Pid, hostport}, Key),
    {ok, Pid}.

del_from_q({empty, Q}, _, _) ->
    Q;
del_from_q({{value, V}, Q}, 0, _Elem) ->
    queue:in(V, Q);
del_from_q({{value, Elem}, Q1}, QSize, Elem) ->
    del_from_q(queue:out(Q1), QSize-1, Elem);
del_from_q({{value, V}, Q}, QSize, Elem) ->
    del_from_q(queue:out(queue:in(V, Q)), QSize-1, Elem);
del_from_q(Q, QSize, Elem) ->
    del_from_q(queue:out(Q), QSize, Elem).

maybe_named_key(Host, Port, Opts) ->
    case lists:keysearch(name, 1, Opts) of
	{value, {name, Pool_name}} when is_atom(Pool_name) ->
	    {Pool_name, Host, Port};
	_ ->
	    {Host, Port}
    end.

% get_value(Tag, TVL) ->
%     {value, {_, V}} = lists:keysearch(Tag,1,TVL),
%     V.

get_value(Tag, TVL, DefVal) ->
    case lists:keysearch(Tag, 1, TVL) of
	{value, {_, V}} ->
	    V;
	false ->
	    DefVal
    end.

do_trace(Fmt, Args) ->
    do_trace(get(my_trace_flag), Fmt, Args).
% do_trace(true, Fmt, Args) ->
%     io:format("~s -- IBROWSE - "++Fmt, [printable_date() | Args]);
do_trace(true, Fmt, Args) ->
    io:format("~s -- IBROWSE - "++Fmt, [printable_date() | Args]);
do_trace(_, _, _) -> ok.
