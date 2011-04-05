%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ebucketmigrator_srv).

-behaviour(gen_server).

-include("ns_common.hrl").

-define(SERVER, ?MODULE).
-define(CONNECT_TIMEOUT, 5000).        % Milliseconds
-define(UPSTREAM_TIMEOUT, 30000000).   % Microseconds because we use timer:now_diff
-define(TIMEOUT_CHECK_INTERVAL, 5000). % Milliseconds

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bad_vbucket_count = 0 :: non_neg_integer(),
                upstream :: port(),
                downstream :: port(),
                upbuf = <<>> :: binary(),
                downbuf = <<>> :: binary(),
                vbuckets,
                takeover :: boolean(),
                takeover_msgs_seen = 0 :: non_neg_integer(),
                last_seen}).

%% external API
-export([start_link/3]).

-include("mc_constants.hrl").
-include("mc_entry.hrl").

%%
%% gen_server callback implementation
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Req, _From, State) ->
    {reply, unhandled, State}.


handle_cast(Msg, State) ->
    ?log_error("Unhandled cast: ~p", [Msg]),
    {noreply, State}.


handle_info({tcp, Socket, Data}, #state{downstream=Downstream,
                                        upstream=Upstream} = State) ->
    %% Set up the socket to receive another message
    ok = inet:setopts(Socket, [{active, once}]),
    State1 = case Socket of
                 Downstream ->
                     process_data(Data, #state.downbuf,
                                  fun process_downstream/2, State);
                 Upstream ->
                     process_data(Data, #state.upbuf,
                                  fun process_upstream/2,
                                  State#state{last_seen=now()})
    end,
    {noreply, State1};
handle_info({tcp_closed, Socket}, #state{upstream=Socket} = State) ->
    case State#state.takeover of
        true ->
            N = sets:size(State#state.vbuckets),
            case State#state.takeover_msgs_seen of
                N ->
                    {stop, normal, State};
                Msgs ->
                    {stop, {wrong_number_takeovers, Msgs, N}, State}
            end;
        false ->
            {stop, normal, State}
    end;
handle_info({tcp_closed, Socket}, #state{downstream=Socket} = State) ->
    {stop, downstream_closed, State};
handle_info(check_for_timeout, State) ->
    case timer:now_diff(now(), State#state.last_seen) > ?UPSTREAM_TIMEOUT of
        true ->
            {stop, timeout, State};
        false ->
            {noreply, State}
    end;
handle_info(Msg, State) ->
    ?log_info("handle_info(~p, ~p)", [Msg, State]),
    {noreply, State}.


init({Src, Dst, Opts}) ->
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts, ""),
    Bucket = proplists:get_value(bucket, Opts),
    VBuckets = proplists:get_value(vbuckets, Opts),
    TakeOver = proplists:get_bool(takeover, Opts),
    TapSuffix = proplists:get_value(suffix, Opts),
    Name = case TakeOver of
               true -> "rebalance_" ++ TapSuffix;
               _ -> "replication_" ++ TapSuffix
           end,
    proc_lib:init_ack({ok, self()}),
    Downstream = connect(Dst, Username, Password, Bucket),
    Upstream = connect(Src, Username, Password, Bucket),
    {ok, quiet} = mc_client_binary:tap_connect(Upstream, [{vbuckets, VBuckets},
                                                          {name, Name},
                                                          {takeover, TakeOver}]),
    ok = inet:setopts(Upstream, [{active, once}]),
    ok = inet:setopts(Downstream, [{active, once}]),

    Timeout = proplists:get_value(timeout, Opts, ?TIMEOUT_CHECK_INTERVAL),
    {ok, _TRef} = timer:send_interval(Timeout, check_for_timeout),

    State = #state{
      upstream=Upstream,
      downstream=Downstream,
      vbuckets=sets:from_list(
                 case VBuckets of
                     undefined -> [0];
                     _ -> VBuckets
                 end),
      last_seen=now(),
      takeover=TakeOver
     },
    gen_server:enter_loop(?MODULE, [], State).


terminate(_Reason, _State) ->
    ok.


%%
%% API
%%

start_link(Src, Dst, Opts) ->
    proc_lib:start_link(?MODULE, init, [{Src, Dst, Opts}]).


%%
%% Internal functions
%%

connect({Host, Port}, Username, Password, Bucket) ->
    {ok, Sock} = gen_tcp:connect(Host, Port,
                                 [binary, {packet, raw}, {active, false},
                                  {recbuf, 10*1024*1024},
                                  {sndbuf, 10*1024*1024}],
                                 ?CONNECT_TIMEOUT),
    case Username of
        undefined ->
            ok;
        _ ->
            ok = mc_client_binary:auth(Sock, {<<"PLAIN">>,
                                              {list_to_binary(Username),
                                               list_to_binary(Password)}})
    end,
    case Bucket of
        undefined ->
            ok;
        _ ->
            ok = mc_client_binary:select_bucket(Sock, Bucket)
    end,
    Sock.


%% @doc Chop up a buffer into packets, calling the callback with each packet.
-spec process_data(binary(), fun((binary(), #state{}) -> {binary(), #state{}}),
                                #state{}) -> {binary(), #state{}}.
process_data(<<_Magic:8, Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
               _VBucket:16, BodyLen:32, _Opaque:32, _CAS:64, _Rest/binary>>
                 = Buffer, CB, State)
  when byte_size(Buffer) >= BodyLen + ?HEADER_LEN ->
    %% We have a complete command
    {Packet, NewBuffer} = split_binary(Buffer, BodyLen + ?HEADER_LEN),
    State1 =
        case Opcode of
            ?NOOP ->
                %% These aren't normal TAP packets; eating them here
                %% makes everything else easier.
                State;
            _ ->
                CB(Packet, State)
        end,
    process_data(NewBuffer, CB, State1);
process_data(Buffer, _CB, State) ->
    %% Incomplete
    {Buffer, State}.


%% @doc Append Data to the appropriate buffer, calling the given
%% callback for each packet.
-spec process_data(binary(), non_neg_integer(),
                   fun((binary(), #state{}) -> #state{}), #state{}) -> #state{}.
process_data(Data, Elem, CB, State) ->
    Buffer = element(Elem, State),
    {NewBuf, NewState} = process_data(<<Buffer/binary, Data/binary>>, CB, State),
    setelement(Elem, NewState, NewBuf).


%% @doc Process a packet from the downstream server.
-spec process_downstream(<<_:8,_:_*8>>, #state{}) ->
                                #state{}.
process_downstream(<<?RES_MAGIC:8, _/binary>> = Packet,
                   State) ->
    ok = gen_tcp:send(State#state.upstream, Packet),
    State.


%% @doc Process a packet from the upstream server.
-spec process_upstream(<<_:64,_:_*8>>, #state{}) ->
                              #state{}.
process_upstream(<<?REQ_MAGIC:8, Opcode:8, _KeyLen:16, _ExtLen:8, _DataType:8,
                   VBucket:16, _BodyLen:32, _Opaque:32, _CAS:64, _EnginePriv:16,
                   _Flags:16, _TTL:8, _Res1:8, _Res2:8, _Res3:8, Rest/binary>> =
                     Packet,
                 #state{downstream=Downstream, vbuckets=VBuckets} = State) ->
    case Opcode of
        ?TAP_OPAQUE ->
            ok = gen_tcp:send(Downstream, Packet),
            State;
        _ ->
            State1 =
                case Opcode of
                    ?TAP_VBUCKET ->
                        case Rest of
                            <<?VB_STATE_ACTIVE:32>> ->
                                true = State#state.takeover,
                                %% VBucket has been transferred, count it
                                State#state{takeover_msgs_seen =
                                                State#state.takeover_msgs_seen
                                            + 1};
                            <<_:32>> -> % Make sure it's still a 32 bit value
                                State
                        end;
                    _ ->
                        State
                end,
            case sets:is_element(VBucket, VBuckets) of
                true ->
                    ok = gen_tcp:send(Downstream, Packet),
                    State1;
                false ->
                    %% Filter it out and count it
                    State1#state{bad_vbucket_count =
                                     State1#state.bad_vbucket_count + 1}
            end
    end.