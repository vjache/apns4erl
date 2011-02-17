%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @copyright (C) 2010 Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @doc apns4erl connection process
%%% @end
%%%-------------------------------------------------------------------
-module(apns_connection).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').

-behaviour(gen_server).

-include("apns.hrl").
-include("localized.hrl").
-include_lib("ssl/src/ssl_int.hrl").

-export([start_link/1, start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([send_message/2, stop/1]).

-record(state, {socket :: #sslsocket{}}).
-type state() :: #state{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc  Sends a message to apple through the connection
%% @spec send_message(apns:conn_id(), #apns_msg{}) -> ok
-spec send_message(apns:conn_id(), #apns_msg{}) -> ok.
send_message(ConnId, Msg) ->
  gen_server:cast(ConnId, Msg).

%% @doc  Stops the connection
%% @spec stop(apns:conn_id()) -> ok
-spec stop(apns:conn_id()) -> ok.
stop(ConnId) ->
  gen_server:cast(ConnId, stop).

%% @hidden
-spec start_link(atom(), #apns_connection{}) -> {ok, pid()} | {error, {already_started, pid()}}.
start_link(Name, Connection) ->
  gen_server:start_link({local, Name}, ?MODULE, Connection, []).
-spec start_link(#apns_connection{}) -> {ok, pid()}.
start_link(Connection) ->
  gen_server:start_link(?MODULE, Connection, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Server implementation, a.k.a.: callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @hidden
-spec init(#apns_connection{}) -> {ok, state()} | {stop, term()}.
init(Connection) ->
  ok = ssl:seed(Connection#apns_connection.ssl_seed),
  try ssl:connect(
         Connection#apns_connection.apple_host,
         Connection#apns_connection.apple_port,
         [{certfile, filename:absname(Connection#apns_connection.cert_file)},
          {ssl_imp, old}, {mode, binary}],
         Connection#apns_connection.timeout) of
    {ok, Socket} ->
      {ok, #state{socket = Socket}}
  catch
    _:{error, Reason} ->
      {stop, Reason}
  end.

%% @hidden
-spec handle_call(X, reference(), state()) -> {stop, {unknown_request, X}, {unknown_request, X}, state()}.
handle_call(Request, _From, State) ->
  {stop, {unknown_request, Request}, {unknown_request, Request}, State}.

%% @hidden
-spec handle_cast(stop | #apns_msg{}, state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
handle_cast(Msg, State) when is_record(Msg, apns_msg) ->
  Socket = State#state.socket,
  Payload = build_payload([{alert, Msg#apns_msg.alert},
                           {badge, Msg#apns_msg.badge},
                           {sound, Msg#apns_msg.sound}], Msg#apns_msg.extra),
  BinToken = hexstr_to_bin(Msg#apns_msg.device_token),
  case send_payload(Socket, BinToken, Payload) of
    ok ->
      {noreply, State};
    {error, Reason} ->
      {stop, {error, Reason}, State}
  end;
handle_cast(stop, State) ->
  {stop, normal, State}.

%% @hidden
-spec handle_info({ssl_closed, #sslsocket{}} | X, state()) -> {stop, ssl_closed | {unknown_request, X}, state()}.
handle_info({ssl_closed, SslSocket}, State = #state{socket = SslSocket}) ->
  {stop, ssl_closed, State};
handle_info(Request, State) ->
  {stop, {unknown_request, Request}, State}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
build_payload(Params, Extra) ->
  do_build_payload(Params, Extra).
do_build_payload([{Key,Value}|Params], Payload) -> 
  case Value of
    Value when is_list(Value) ->
      do_build_payload(Params, [{atom_to_binary(Key, utf8), unicode:characters_to_binary(Value)} | Payload]);
    Value when is_integer(Value) ->
      do_build_payload(Params, [{atom_to_binary(Key, utf8), Value} | Payload]);
    #loc_alert{action = Action,
               args   = Args,
               body   = Body,
               image  = Image,
               key    = LocKey} ->
      Json = {case Body of
                none -> [];
                Body -> [{<<"body">>, unicode:characters_to_binary(Body)}]
              end ++ case Action of
                       none -> [];
                       Action -> [{<<"action-loc-key">>, unicode:characters_to_binary(Action)}]
                     end ++ case Image of
                              none -> [];
                              Image -> [{<<"launch-image">>, unicode:characters_to_binary(Image)}]
                            end ++
                [{<<"loc-key">>, unicode:characters_to_binary(LocKey)},
                 {<<"loc-args">>, lists:map(fun unicode:characters_to_binary/1, Args)}]},
      do_build_payload(Params, [{atom_to_binary(Key, utf8), Json} | Payload]);
    _ ->
      do_build_payload(Params,Payload)
  end;
do_build_payload([], Payload) ->
  apns_mochijson2:encode(Payload).

-spec send_payload(#sslsocket{}, binary(), iolist()) -> ok | {error, term()}.
send_payload(Socket, BinToken, Payload) -> 
    BinPayload = list_to_binary(Payload),
    PayloadLength = erlang:size(BinPayload),
    Packet = [<<0:8, 32:16/big,
                %%16#ac812b2d723f40f206204402f1c870c8d8587799370bd41d6723145c4e4ebbd7:256/big,
                BinToken/binary,
                PayloadLength:16/big,
                BinPayload/binary>>],
    error_logger:info_msg("Sending:~s~n", [BinPayload]),
    ssl:send(Socket, Packet).

hexstr_to_bin(S) ->
  hexstr_to_bin(S, []).
hexstr_to_bin([], Acc) ->
  list_to_binary(lists:reverse(Acc));
hexstr_to_bin([X,Y|T], Acc) ->
  {ok, [V], []} = io_lib:fread("~16u", [X,Y]),
  hexstr_to_bin(T, [V | Acc]).