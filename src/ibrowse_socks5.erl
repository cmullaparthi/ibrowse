-module(ibrowse_socks5).

-include_lib("kernel/src/inet_dns.hrl").

-export([connect/3]).

-define(TIMEOUT, 2000).

-define(SOCKS5, 5).
-define(AUTH_METHOD_NO, 0).
-define(AUTH_METHOD_USERPASS, 2).
-define(ADDRESS_TYPE_IP4, 1).
-define(COMMAND_TYPE_TCPIP_STREAM, 1).
-define(RESERVER, 0).
-define(STATUS_GRANTED, 0).

-define(DNS_IP, {8,8,8,8}).

connect(Host, Port, Options) ->
    Socks5Host = proplists:get_value(socks5_host, Options),
    Socks5Port = proplists:get_value(socks5_port, Options),

    {ok, Socket} = gen_tcp:connect(Socks5Host, Socks5Port, [binary, {packet, 0}, {keepalive, true}, {active, false}]),

    case proplists:get_value(socks5_user, Options, undefined) of
        undefined ->
            ok = gen_tcp:send(Socket, <<?SOCKS5, 1, ?AUTH_METHOD_NO>>),
            {ok, <<?SOCKS5, ?AUTH_METHOD_NO>>} = gen_tcp:recv(Socket, 2, ?TIMEOUT);
        _Else ->
            Socks5User = list_to_binary(proplists:get_value(socks5_user, Options)),
            Socks5Pass = list_to_binary(proplists:get_value(socks5_pass, Options)),

            ok = gen_tcp:send(Socket, <<?SOCKS5, 1, ?AUTH_METHOD_USERPASS>>),
            {ok, <<?SOCKS5, ?AUTH_METHOD_USERPASS>>} = gen_tcp:recv(Socket, 2, ?TIMEOUT),

            UserLength = byte_size(Socks5User),

            ok = gen_tcp:send(Socket, << 1, UserLength >>),
            ok = gen_tcp:send(Socket, Socks5User),
            PassLength = byte_size(Socks5Pass),
            ok = gen_tcp:send(Socket, << PassLength >>),
            ok = gen_tcp:send(Socket, Socks5Pass),
            {ok, <<1, 0>>} = gen_tcp:recv(Socket, 2, ?TIMEOUT)
    end,

    {IP1,IP2,IP3,IP4} = case inet_parse:address(Host) of
        {ok, IP} ->
            IP;
        _Other ->
            {ok, NsData} = inet_res:nslookup(Host, in, a, [{?DNS_IP, 53}]),
            [Addr | _NewAnList] = [D || #dns_rr{data=D, type=a} <- NsData#dns_rec.anlist],
            Addr
    end,

    ok = gen_tcp:send(Socket, <<?SOCKS5, ?COMMAND_TYPE_TCPIP_STREAM, ?RESERVER, ?ADDRESS_TYPE_IP4, IP1, IP2, IP3, IP4, Port:16>>),
    {ok, << ?SOCKS5, ?STATUS_GRANTED, ?RESERVER, ?ADDRESS_TYPE_IP4, IP1, IP2, IP3, IP4, Port:16 >>} = gen_tcp:recv(Socket, 10, ?TIMEOUT),
    {ok, Socket}.
