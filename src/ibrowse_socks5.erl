% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(ibrowse_socks5).

-define(VERSION, 5).
-define(CONNECT, 1).

-define(NO_AUTH, 0).
-define(USERPASS, 2).
-define(UNACCEPTABLE, 16#FF).
-define(RESERVED, 0).

-define(ATYP_IPV4, 1).
-define(ATYP_DOMAINNAME, 3).
-define(ATYP_IPV6, 4).

-define(SUCCEEDED, 0).

-export([connect/5]).

-import(ibrowse_lib, [get_value/2, get_value/3]).

connect(Host, Port, Options, SockOptions, Timeout) ->
    Socks5Host = get_value(socks5_host, Options),
    Socks5Port = get_value(socks5_port, Options),
    case gen_tcp:connect(Socks5Host, Socks5Port, SockOptions, Timeout) of
        {ok, Socket} ->
            case handshake(Socket, Options) of
                ok ->
                    case connect(Host, Port, Socket) of
                        ok ->
                            {ok, Socket};
                        Else ->
                            gen_tcp:close(Socket),
                            Else
                    end;
                Else ->
                    gen_tcp:close(Socket),
                    Else
            end;
        Else ->
            Else
    end.

handshake(Socket, Options) when is_port(Socket) ->
    User = get_value(socks5_user, Options, <<>>),
    Handshake_msg = case User of
                        <<>> ->
                            <<?VERSION, 1, ?NO_AUTH>>;
                        User ->
                            <<?VERSION, 1, ?USERPASS>>
                    end,
    ok = gen_tcp:send(Socket, Handshake_msg),
    case gen_tcp:recv(Socket, 2) of
        {ok, <<?VERSION, ?NO_AUTH>>} ->
            ok;
        {ok, <<?VERSION, ?USERPASS>>} ->
            Password = get_value(socks5_password, Options, <<>>),
            Auth_msg = list_to_binary([1, 
                                       iolist_size(User), User,
                                       iolist_size(Password), Password]),
            ok = gen_tcp:send(Socket, Auth_msg),
            case gen_tcp:recv(Socket, 2) of
                {ok, <<1, ?SUCCEEDED>>} ->
                    ok;
                _ ->
                    {error, unacceptable}
            end;
        {ok, <<?VERSION, ?UNACCEPTABLE>>} ->
            {error, unacceptable};
        {error, Reason} ->
            {error, Reason}
    end.

connect(Host, Port, Via) when is_list(Host) ->
    connect(list_to_binary(Host), Port, Via);
connect(Host, Port, Via) when is_binary(Host), is_integer(Port),
                              is_port(Via) ->
    {AddressType, Address} = case inet:parse_address(binary_to_list(Host)) of
                                 {ok, {IP1, IP2, IP3, IP4}} ->
                                     {?ATYP_IPV4, <<IP1,IP2,IP3,IP4>>};
                                 {ok, {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}} ->
                                     {?ATYP_IPV6, <<IP1,IP2,IP3,IP4,IP5,IP6,IP7,IP8>>};
                                 _ ->
                                     HostLength = byte_size(Host),
                                     {?ATYP_DOMAINNAME, <<HostLength,Host/binary>>}
                             end,
    ok = gen_tcp:send(Via,
                      <<?VERSION, ?CONNECT, ?RESERVED,
                        AddressType, Address/binary,
                        (Port):16>>),
    case gen_tcp:recv(Via, 0) of
        {ok, <<?VERSION, ?SUCCEEDED, ?RESERVED, _/binary>>} ->
            ok;
        {ok, <<?VERSION, Rep, ?RESERVED, _/binary>>} ->
            {error, rep(Rep)};
        {error, Reason} ->
            {error, Reason}
    end.

rep(0) -> succeeded;
rep(1) -> server_fail;
rep(2) -> disallowed_by_ruleset;
rep(3) -> network_unreachable;
rep(4) -> host_unreachable;
rep(5) -> connection_refused;
rep(6) -> ttl_expired;
rep(7) -> command_not_supported;
rep(8) -> address_type_not_supported.
