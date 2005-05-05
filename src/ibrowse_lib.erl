%%% File    : ibrowse_lib.erl
%%% Author  : Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>
%%% Description : 
%%% Created : 27 Feb 2004 by Chandrashekhar Mullaparthi <chandrashekhar.mullaparthi@t-mobile.co.uk>
%% @doc Module with a few useful functions

-module(ibrowse_lib).
-vsn('$Id: ibrowse_lib.erl,v 1.1 2005/05/05 22:28:28 chandrusf Exp $ ').
-author('chandru').
-ifdef(debug).
-compile(export_all).
-endif.

-export([url_encode/1,
	 decode_rfc822_date/1,
	 status_code/1,
	 drv_ue/1,
	 drv_ue/2]).

drv_ue(Str) ->
    [{port, Port}| _] = ets:lookup(ibrowse_table, port),
    drv_ue(Str, Port).
drv_ue(Str, Port) ->
    case erlang:port_control(Port, 1, Str) of
	[] ->
	    Str;
	Res ->
	    Res
    end.

%% @doc URL-encodes a string based on RFC 1738. Returns a flat list.
%% @spec url_encode(Str) -> UrlEncodedStr
%% Str = string()
%% UrlEncodedStr = string()
url_encode(Str) when list(Str) ->
    url_encode_char(lists:reverse(Str), []).

url_encode_char([X | T], Acc) when X >= $a, X =< $z ->
    url_encode_char(T, [X | Acc]);
url_encode_char([X | T], Acc) when X >= $A, X =< $Z ->
    url_encode_char(T, [X | Acc]);
url_encode_char([X | T], Acc) when X == $-; X == $_; X == $. ->
    url_encode_char(T, [X | Acc]);
url_encode_char([32 | T], Acc) ->
    url_encode_char(T, [$+ | Acc]);
url_encode_char([X | T], Acc) ->
    url_encode_char(T, [$%, d2h(X bsr 4), d2h(X band 16#0f) | Acc]);
url_encode_char([], Acc) ->
    Acc.
    
d2h(N) when N<10 -> N+$0;
d2h(N) -> N+$a-10.

decode_rfc822_date(String) when list(String) ->
    case catch decode_rfc822_date_1(string:tokens(String, ", \t\r\n")) of
	{'EXIT', _} ->
	    {error, invalid_date};
	Res ->
	    Res
    end.

% TODO: Have to handle the Zone
decode_rfc822_date_1([_,DayInt,Month,Year, Time,Zone]) ->
    decode_rfc822_date_1([DayInt,Month,Year, Time,Zone]);
decode_rfc822_date_1([Day,Month,Year, Time,_Zone]) ->
    DayI = list_to_integer(Day),
    MonthI = month_int(Month),
    YearI = list_to_integer(Year),
    TimeTup = case string:tokens(Time, ":") of
		  [H,M] ->
		      {list_to_integer(H),
		       list_to_integer(M),
		       0};
		  [H,M,S] ->
		      {list_to_integer(H),
		       list_to_integer(M),
		       list_to_integer(S)}
	      end,
    {{YearI,MonthI,DayI}, TimeTup}.

month_int("Jan") -> 1;
month_int("Feb") -> 2;
month_int("Mar") -> 3;
month_int("Apr") -> 4;
month_int("May") -> 5;
month_int("Jun") -> 6;
month_int("Jul") -> 7;
month_int("Aug") -> 8;
month_int("Sep") -> 9;
month_int("Oct") -> 10;
month_int("Nov") -> 11;
month_int("Dec") -> 12.

%% @doc Given a status code, returns an atom describing the status code. 
%% @spec status_code(StatusCode) -> StatusDescription
%% StatusCode = string() | integer()
%% StatusDescription = atom()
status_code(100) -> continue;
status_code(101) -> switching_protocols;
status_code(200) -> ok;
status_code(201) -> created;
status_code(202) -> accepted;
status_code(203) -> non_authoritative_information;
status_code(204) -> no_content;
status_code(205) -> reset_content;
status_code(206) -> partial_content;
status_code(300) -> multiple_choices;
status_code(301) -> moved_permanently;
status_code(302) -> found;
status_code(303) -> see_other;
status_code(304) -> not_modified;
status_code(305) -> use_proxy;
status_code(306) -> unused;
status_code(307) -> temporary_redirect;
status_code(400) -> bad_request;
status_code(401) -> unauthorized;
status_code(402) -> payment_required;
status_code(403) -> forbidden;
status_code(404) -> not_found;
status_code(405) -> method_not_allowed;
status_code(406) -> not_acceptable;
status_code(407) -> proxy_authentication_required;
status_code(408) -> request_tunnel;
status_code(408) -> request_timeout;
status_code(409) -> conflict;
status_code(410) -> gone;
status_code(411) -> length_required;
status_code(412) -> precondition_failed;
status_code(413) -> request_entity_too_large;
status_code(414) -> request_uri_too_long;
status_code(415) -> unsupported_media_type;
status_code(416) -> requested_range_not_satisfiable;
status_code(417) -> expectation_failed;
status_code(500) -> internal_server_error;
status_code(501) -> not_implemented;
status_code(502) -> bad_gateway;
status_code(503) -> service_unavailable;
status_code(504) -> gateway_timeout;
status_code(505) -> http_version_not_supported;
status_code(X) when is_list(X) -> status_code(list_to_integer(X));
status_code(_)   -> unknown_status_code.
