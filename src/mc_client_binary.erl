%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").
-include("mc_constants.hrl").
-include("mc_entry.hrl").

%% we normally speak to local memcached when issuing delete
%% vbucket. Thus timeout needs to only cover ep-engine going totally
%% insane.
-define(VB_DELETE_TIMEOUT, 300000).

-export([auth/2,
         cmd/5,
         create_bucket/4,
         delete_bucket/3,
         delete_vbucket/2,
         flush/1,
         get_vbucket/2,
         list_buckets/1,
         get_last_closed_checkpoint/2,
         create_new_checkpoint/2,
         refresh_isasl/1,
         noop/1,
         select_bucket/2,
         set_flush_param/3,
         set_vbucket/3,
         stats/1,
         stats/4,
         tap_connect/2,
         deregister_tap_client/2,
         sync/4,
         get_meta/3,
         set_with_meta/8,
         add_with_meta/7,
         delete_with_meta/5,
         set_engine_param/4,
         get_zero_open_checkpoint_vbuckets/2,
         change_vbucket_filter/3,
         enable_traffic/1]).

-type recv_callback() :: fun((_, _, _) -> any()) | undefined.
-type mc_timeout() :: undefined | infinity | non_neg_integer().
-type mc_opcode() :: ?GET | ?SET | ?ADD | ?REPLACE | ?DELETE | ?INCREMENT |
                     ?DECREMENT | ?QUIT | ?FLUSH | ?GETQ | ?NOOP | ?VERSION |
                     ?GETK | ?GETKQ | ?APPEND | ?PREPEND | ?STAT | ?SETQ |
                     ?ADDQ | ?REPLACEQ | ?DELETEQ | ?INCREMENTQ | ?DECREMENTQ |
                     ?QUITQ | ?FLUSHQ | ?APPENDQ | ?PREPENDQ |
                     ?CMD_SASL_LIST_MECHS | ?CMD_SASL_AUTH | ?CMD_SASL_STEP |
                     ?CMD_CREATE_BUCKET | ?CMD_DELETE_BUCKET |
                     ?CMD_LIST_BUCKETS | ?CMD_EXPAND_BUCKET |
                     ?CMD_SELECT_BUCKET | ?CMD_SET_PARAM |
                     ?CMD_SET_VBUCKET | ?CMD_GET_VBUCKET | ?CMD_DELETE_VBUCKET |
                     ?CMD_LAST_CLOSED_CHECKPOINT | ?CMD_ISASL_REFRESH |
                     ?CMD_GET_META | ?CMD_GETQ_META | ?CMD_CREATE_CHECKPOINT |
                     ?CMD_SET_WITH_META | ?CMD_SETQ_WITH_META |
                     ?CMD_ADD_WITH_META | ?CMD_SETQ_WITH_META |
                     ?CMD_DEL_WITH_META | ?CMD_DELQ_WITH_META |
                     ?RGET | ?RSET | ?RSETQ | ?RAPPEND | ?RAPPENDQ | ?RPREPEND |
                     ?RPREPENDQ | ?RDELETE | ?RDELETEQ | ?RINCR | ?RINCRQ |
                     ?RDECR | ?RDECRQ | ?SYNC.

%% A memcached client that speaks binary protocol.
-spec cmd(mc_opcode(), port(), recv_callback(), any(),
          {#mc_header{}, #mc_entry{}}) ->
                 {ok, #mc_header{}, #mc_entry{}, any()} | {ok, quiet}.
cmd(Opcode, Sock, RecvCallback, CBData, HE) ->
    cmd(Opcode, Sock, RecvCallback, CBData, HE, undefined).

-spec cmd(mc_opcode(), port(), recv_callback(), any(),
          {#mc_header{}, #mc_entry{}}, mc_timeout()) ->
                 {ok, #mc_header{}, #mc_entry{}, any()} | {ok, quiet}.
cmd(Opcode, Sock, RecvCallback, CBData, HE, Timeout) ->
    case is_quiet(Opcode) of
        true  -> cmd_binary_quiet(Opcode, Sock, RecvCallback, CBData, HE);
        false -> cmd_binary_vocal(Opcode, Sock, RecvCallback, CBData, HE,
                                  Timeout)
    end.

cmd_binary_quiet(Opcode, Sock, _RecvCallback, _CBData, {Header, Entry}) ->
    ok = mc_binary:send(Sock, req,
              Header#mc_header{opcode = Opcode}, ext(Opcode, Entry)),
    {ok, quiet}.

cmd_binary_vocal(?STAT = Opcode, Sock, RecvCallback, CBData,
                 {Header, Entry}, Timeout) ->
    ok = mc_binary:send(Sock, req, Header#mc_header{opcode = Opcode}, Entry),
    stats_recv(Sock, RecvCallback, CBData, Timeout);

cmd_binary_vocal(Opcode, Sock, RecvCallback, CBData, {Header, Entry},
                 Timeout) ->
    ok = mc_binary:send(Sock, req,
              Header#mc_header{opcode = Opcode}, ext(Opcode, Entry)),
    cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, CBData, Timeout).

cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, CBData, Timeout) ->
    {ok, RecvHeader, RecvEntry} = mc_binary:recv(Sock, res, Timeout),
    NCB = case is_function(RecvCallback) of
              true  -> RecvCallback(RecvHeader, RecvEntry, CBData);
              false -> CBData
          end,
    case Opcode =:= RecvHeader#mc_header.opcode of
        true  -> {ok, RecvHeader, RecvEntry, NCB};
        false -> cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, NCB, Timeout)
    end.

% -------------------------------------------------

stats_recv(Sock, RecvCallback, State, Timeout) ->
    {ok, #mc_header{opcode = ROpcode,
                    keylen = RKeyLen} = RecvHeader, RecvEntry} =
        mc_binary:recv(Sock, res, Timeout),
    case ?STAT =:= ROpcode andalso 0 =:= RKeyLen of
        true  -> {ok, RecvHeader, RecvEntry, State};
        false -> NCB = case is_function(RecvCallback) of
                           true  -> RecvCallback(RecvHeader, RecvEntry, State);
                           false -> State
                       end,
                 stats_recv(Sock, RecvCallback, NCB, Timeout)
    end.

% -------------------------------------------------

auth(_Sock, undefined) -> ok;

auth(Sock, {<<"PLAIN">>, {AuthName, undefined}}) ->
    auth(Sock, {<<"PLAIN">>, {<<>>, AuthName, <<>>}});

auth(Sock, {<<"PLAIN">>, {AuthName, AuthPswd}}) ->
    auth(Sock, {<<"PLAIN">>, {<<>>, AuthName, AuthPswd}});

auth(Sock, {<<"PLAIN">>, {ForName, AuthName, undefined}}) ->
    auth(Sock, {<<"PLAIN">>, {ForName, AuthName, <<>>}});

auth(Sock, {<<"PLAIN">>, {ForName, AuthName, AuthPswd}}) ->
    BinForName  = mc_binary:bin(ForName),
    BinAuthName = mc_binary:bin(AuthName),
    BinAuthPswd = mc_binary:bin(AuthPswd),
    case cmd(?CMD_SASL_AUTH, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = <<"PLAIN">>,
                        data = <<BinForName/binary, 0:8,
                                 BinAuthName/binary, 0:8,
                                 BinAuthPswd/binary>>
                       }}) of
        {ok, #mc_header{status=?SUCCESS}, _, _} ->
            ok;
        Other ->
            process_error_response(Other)
    end;
auth(_Sock, _UnknownMech) ->
    {error, emech_unsupported}.

% -------------------------------------------------

sync(Sock, VBucket, Key, CAS) ->
    Sync = build_sync_flags(Key, VBucket, CAS),
    cmd(?SYNC, Sock, undefined, undefined,
        {#mc_header{}, #mc_entry{data = Sync}}).

create_bucket(Sock, BucketName, Engine, Config) ->
    case cmd(?CMD_CREATE_BUCKET, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = BucketName,
                        data = list_to_binary([Engine, 0, Config])}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

%% This can take an arbitrary period of time.
delete_bucket(Sock, BucketName, Options) ->
    Force = proplists:get_bool(force, Options),
    Config = io_lib:format("force=~s", [Force]),
    case cmd(?CMD_DELETE_BUCKET, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = BucketName,
                        data = iolist_to_binary(Config)}}, infinity) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

delete_vbucket(Sock, VBucket) ->
    case cmd(?CMD_DELETE_VBUCKET, Sock, undefined, undefined,
             {#mc_header{vbucket = VBucket}, #mc_entry{}},
             ?VB_DELETE_TIMEOUT) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

flush(Sock) ->
    case cmd(?FLUSH, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

decode_vb_state(<<?VB_STATE_ACTIVE:32>>)  -> active;
decode_vb_state(<<?VB_STATE_REPLICA:32>>) -> replica;
decode_vb_state(<<?VB_STATE_PENDING:32>>) -> pending;
decode_vb_state(<<?VB_STATE_DEAD:32>>)    -> dead.

get_vbucket(Sock, VBucket) ->
    case cmd(?CMD_GET_VBUCKET, Sock, undefined, undefined,
            {#mc_header{vbucket = VBucket},
             #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, #mc_entry{data=StateBin}, _NCB} ->
            {ok, decode_vb_state(StateBin)};
        Response -> process_error_response(Response)
    end.

list_buckets(Sock) ->
    case cmd(?CMD_LIST_BUCKETS, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, #mc_entry{data=BucketsBin}, _NCB} ->
            case BucketsBin of
                undefined -> {ok, []};
                _ -> {ok, string:tokens(binary_to_list(BucketsBin), " ")}
            end;
        Response -> process_error_response(Response)
    end.

get_last_closed_checkpoint(Sock, VBucket) ->
    case cmd(?CMD_LAST_CLOSED_CHECKPOINT, Sock, undefined, undefined,
            {#mc_header{vbucket = VBucket},
             #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, #mc_entry{data=CheckpointBin}, _NCB} ->
            <<Checkpoint:64>> = CheckpointBin,
            {ok, Checkpoint};
        Response -> process_error_response(Response)
    end.

create_new_checkpoint(Sock, VBucket) ->
    case cmd(?CMD_CREATE_CHECKPOINT, Sock, undefined, undefined,
             {#mc_header{vbucket = VBucket}, #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, #mc_entry{data=CheckpointBin}, _NCB} ->
            <<Checkpoint:64>> = CheckpointBin,
            {ok, Checkpoint};
        Response -> process_error_response(Response)
    end.

refresh_isasl(Sock) ->
    case cmd(?CMD_ISASL_REFRESH, Sock, undefined, undefined, {#mc_header{}, #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, _, _} ->
            ok;
        Response -> process_error_response(Response)
    end.

noop(Sock) ->
    case cmd(?NOOP, Sock, undefined, undefined, {#mc_header{}, #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, #mc_entry{}, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

select_bucket(Sock, BucketName) ->
    case cmd(?CMD_SELECT_BUCKET, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = BucketName}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

set_flush_param(Sock, Key, Value) ->
    set_engine_param(Sock, Key, Value, flush).

engine_param_type_to_int(flush) ->
    1;
engine_param_type_to_int(tap) ->
    2;
engine_param_type_to_int(checkpoint) ->
    3.

-spec set_engine_param(port(), binary(), binary(), flush | tap | checkpoint) -> ok | mc_error().
set_engine_param(Sock, Key, Value, Type) ->
    ParamType = engine_param_type_to_int(Type),
    Entry = #mc_entry{key = Key,
                      data = Value,
                      ext = <<ParamType:32/big>>},
    case cmd(?CMD_SET_PARAM, Sock, undefined, undefined,
             {#mc_header{}, Entry}) of
        {ok, #mc_header{status=?SUCCESS}, _, _} ->
            ok;
        Response ->
            process_error_response(Response)
    end.

set_vbucket(Sock, VBucket, VBucketState) ->
    State = case VBucketState of
                active  -> ?VB_STATE_ACTIVE;
                replica -> ?VB_STATE_REPLICA;
                pending -> ?VB_STATE_PENDING;
                dead    -> ?VB_STATE_DEAD
            end,
    case cmd(?CMD_SET_VBUCKET, Sock, undefined, undefined,
             {#mc_header{vbucket = VBucket},
              #mc_entry{data = <<State:32>>}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

stats(Sock) ->
    stats(Sock, <<>>, fun (K, V, Acc) -> [{K, V}|Acc] end, []).

stats(Sock, Key, CB, CBData) ->
    case cmd(?STAT, Sock,
             fun (_MH, ME, CD) ->
                     CB(ME#mc_entry.key, ME#mc_entry.data, CD)
             end,
             CBData,
             {#mc_header{}, #mc_entry{key=Key}}) of
        {ok, #mc_header{status=?SUCCESS}, _E, Stats} ->
            {ok, Stats};
        Response -> process_error_response(Response)
    end.

%% @doc Start TAP on an existing connection. At the moment, the caller
%% is responsible for processing the TAP messages that come over the
%% socket.
%%
%% @spec tap_connect(Sock::port(), Opts::[{vbuckets, [integer()]} |
%%                                        takeover | {name, binary()}]) -> ok.
tap_connect(Sock, Opts) ->
    Flags = ?BACKFILL bor ?SUPPORT_ACK bor
        case proplists:get_value(vbuckets, Opts) of
            undefined -> 0;
            _         -> ?LIST_VBUCKETS
        end bor
        case proplists:get_bool(takeover, Opts) of
            true  -> ?TAKEOVER_VBUCKETS;
            false -> 0
        end bor
        case proplists:get_value(checkpoints, Opts) of
            undefined -> 0;
            _ -> ?CHECKPOINT
        end,
    Timestamp = 0,
    Extra = case proplists:get_value(vbuckets, Opts) of
                undefined ->
                    <<>>;
                VBuckets ->
                    NumVBuckets = length(VBuckets),
                    <<NumVBuckets:16, << <<VBucket:16>> || VBucket <- VBuckets>>/binary >>
            end,
    CheckpointMap = case proplists:get_value(checkpoints, Opts) of
                    undefined ->
                        <<>>;
                    Pairs ->
                        NumPairs = length(Pairs),
                        <<NumPairs:16, << <<VBucket:16, Checkpoint:64>> || {VBucket, Checkpoint} <- Pairs>>/binary >>
                    end,
    Data = <<Timestamp:64, Extra/binary, CheckpointMap/binary>>,
    cmd(?TAP_CONNECT, Sock, undefined, undefined,
        {#mc_header{}, #mc_entry{key = proplists:get_value(name, Opts),
                                 ext = <<Flags:32>>,
                                 data = Data}}).

get_meta(Sock, Key, VBucket) ->
    case cmd(?CMD_GET_META, Sock, undefined, undefined,
             {#mc_header{vbucket = VBucket},
              #mc_entry{key = Key}}) of
        {ok, #mc_header{status=?SUCCESS} = Header,
             #mc_entry{data=MetaBin} = Entry, _NCB} ->
            {ok, Header, Entry, decode_meta(MetaBin)};
        {ok, #mc_header{status=?KEY_ENOENT},
             #mc_entry{cas=CAS}, _NCB} ->
            {memcached_error, key_enoent, CAS};
        Response ->
            process_error_response(Response)
    end.

decode_meta(<<?META_REVID:8/big, Length:8/big, SeqNo:32/big, RevId/binary>>)
  when size(RevId) =:= (Length - 4) ->
    {revid, {SeqNo, RevId}};
decode_meta(Data) ->
    {unknown, Data}.

-spec set_with_meta(Sock :: port(), Key :: binary(),
                    VBucket :: integer(), Value :: binary(),
                    Meta :: any(),
                    Cas :: integer(),
                    Flags :: integer(),
                    Expiration :: integer()) -> {ok, #mc_header{}, #mc_entry{}} |
                                                {error, invalid_meta} |
                                                {memcached_error, atom(), binary()}.
set_with_meta(Sock, Key, VBucket, Value, Meta, CAS, Flags, Expiration) ->
    meta_cmd(Sock, ?CMD_SET_WITH_META,
             Key, VBucket, Value, Meta, CAS, Flags, Expiration).

-spec add_with_meta(Sock :: port(), Key :: binary(),
                    VBucket :: integer(), Value :: binary(),
                    Meta :: any(),
                    Flags :: integer(),
                    Expiration :: integer()) -> {ok, #mc_header{}, #mc_entry{}} |
                                                {error, invalid_meta} |
                                                mc_error().
add_with_meta(Sock, Key, VBucket, Value, Meta, Flags, Expiration) ->
    meta_cmd(Sock, ?CMD_ADD_WITH_META,
             Key, VBucket, Value, Meta, 0, Flags, Expiration).

delete_with_meta(Sock, Key, VBucket, Meta, CAS) ->
    case encode_meta(Meta) of
        {ok, MetaBin} ->
            MetaLen = size(MetaBin),
            Response = cmd(?CMD_DEL_WITH_META, Sock, undefined, undefined,
                           {#mc_header{vbucket = VBucket},
                            #mc_entry{key = Key, data = MetaBin,
                                      ext = <<MetaLen:32/big>>, cas = CAS}}),
            case Response of
                {ok, #mc_header{status=?SUCCESS} = RespHeader, RespEntry, _} ->
                    {ok, RespHeader, RespEntry};
                _ ->
                    process_error_response(Response)
            end;
        Error ->
            Error
    end.

encode_meta({revid, {SeqNo, RevId}})
  when is_integer(SeqNo), is_binary(RevId) ->
    Length = size(RevId) + 4,
    {ok, <<?META_REVID:8/big, Length:8/big, SeqNo:32/big, RevId/binary>>};
encode_meta(_Other) ->
    {error, invalid_meta}.

meta_cmd(Sock, Cmd, Key, VBucket, Value, Meta, CAS, Flags, Expiration) ->
    case encode_meta(Meta) of
        {ok, MetaBin} ->
            MetaLen = size(MetaBin),
            Ext = <<MetaLen:32/big, Flags:32/big, Expiration:32/big>>,
            Data = <<Value/binary, MetaBin/binary>>,

            Header = #mc_header{vbucket = VBucket},
            Entry = #mc_entry{key = Key, data = Data, ext = Ext,
                              flag = Flags, expire = Expiration, cas = CAS},

            Response = cmd(Cmd, Sock, undefined, undefined, {Header, Entry}),
            case Response of
                {ok, #mc_header{status=?SUCCESS} = RespHeader, RespEntry, _} ->
                    {ok, RespHeader, RespEntry};
                _ ->
                    process_error_response(Response)
            end;
        Error ->
            Error
    end.

-spec deregister_tap_client(Sock::port(), TapName::binary()) -> ok.
deregister_tap_client(Sock, TapName) ->
    HeaderEntry = {#mc_header{}, #mc_entry{key = TapName}},
    {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} =
        cmd(?CMD_DEREGISTER_TAP_CLIENT, Sock, undefined, undefined, HeaderEntry),
    ok.

-spec change_vbucket_filter(port(), binary(),
                            [{vbucket_id(), checkpoint_id()}]) -> ok | mc_error().
change_vbucket_filter(Sock, TapName, VBuckets) ->
    VBucketsCount = length(VBuckets),
    Data =
        << VBucketsCount:16,
           << <<V:16, C:64>> || {V, C} <- VBuckets >>/binary >>,

    case cmd(?CMD_CHANGE_VB_FILTER, Sock, undefined, undefined,
             {#mc_header{}, #mc_entry{key = TapName,
                                      data = Data}}) of
        {ok, #mc_header{status=?SUCCESS}, _, _} ->
            ok;
        Other ->
            process_error_response(Other)
    end.

enable_traffic(Sock) ->
    case cmd(?CMD_ENABLE_TRAFFIC, Sock, undefined, undefined,
             {#mc_header{}, #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, _, _} ->
            ok;
        Other ->
            process_error_response(Other)
    end.

%% -------------------------------------------------

is_quiet(?GETQ)       -> true;
is_quiet(?GETKQ)      -> true;
is_quiet(?SETQ)       -> true;
is_quiet(?ADDQ)       -> true;
is_quiet(?REPLACEQ)   -> true;
is_quiet(?DELETEQ)    -> true;
is_quiet(?INCREMENTQ) -> true;
is_quiet(?DECREMENTQ) -> true;
is_quiet(?QUITQ)      -> true;
is_quiet(?FLUSHQ)     -> true;
is_quiet(?APPENDQ)    -> true;
is_quiet(?PREPENDQ)   -> true;
is_quiet(?RSETQ)      -> true;
is_quiet(?RAPPENDQ)   -> true;
is_quiet(?RPREPENDQ)  -> true;
is_quiet(?RDELETEQ)   -> true;
is_quiet(?RINCRQ)     -> true;
is_quiet(?RDECRQ)     -> true;
is_quiet(?TAP_CONNECT) -> true;
is_quiet(?CMD_GETQ_META) -> true;
is_quiet(?CMD_SETQ_WITH_META) -> true;
is_quiet(?CMD_ADDQ_WITH_META) -> true;
is_quiet(?CMD_DELQ_WITH_META) -> true;
is_quiet(_)           -> false.

ext(?SET,        Entry) -> ext_flag_expire(Entry);
ext(?SETQ,       Entry) -> ext_flag_expire(Entry);
ext(?ADD,        Entry) -> ext_flag_expire(Entry);
ext(?ADDQ,       Entry) -> ext_flag_expire(Entry);
ext(?REPLACE,    Entry) -> ext_flag_expire(Entry);
ext(?REPLACEQ,   Entry) -> ext_flag_expire(Entry);
ext(?INCREMENT,  Entry) -> ext_arith(Entry);
ext(?INCREMENTQ, Entry) -> ext_arith(Entry);
ext(?DECREMENT,  Entry) -> ext_arith(Entry);
ext(?DECREMENTQ, Entry) -> ext_arith(Entry);
ext(_, Entry) -> Entry.

ext_flag_expire(#mc_entry{ext = Ext, flag = Flag, expire = Expire} = Entry) ->
    case Ext of
        undefined -> Entry#mc_entry{ext = <<Flag:32, Expire:32>>}
    end.

ext_arith(#mc_entry{ext = Ext, data = Data, expire = Expire} = Entry) ->
    case Ext of
        undefined ->
            Ext2 = case Data of
                       <<>>      -> <<1:64, 0:64, Expire:32>>;
                       undefined -> <<1:64, 0:64, Expire:32>>;
                       _         -> <<Data:64, 0:64, Expire:32>>
                   end,
            Entry#mc_entry{ext = Ext2, data = undefined}
    end.

map_status(?KEY_ENOENT) ->
    key_enoent;
map_status(?KEY_EEXISTS) ->
    key_eexists;
map_status(?E2BIG) ->
    e2big;
map_status(?EINVAL) ->
    einval;
map_status(?NOT_STORED) ->
    not_stored;
map_status(?DELTA_BADVAL) ->
    delta_badval;
map_status(?NOT_MY_VBUCKET) ->
    not_my_vbucket;
map_status(?UNKNOWN_COMMAND) ->
    unknown_command;
map_status(?ENOMEM) ->
    enomem;
map_status(?NOT_SUPPORTED) ->
    not_supported;
map_status(?EINTERNAL) ->
    internal;
map_status(?EBUSY) ->
    ebusy;
map_status(?ETMPFAIL) ->
    etmpfail;
map_status(?MC_AUTH_ERROR) ->
    auth_error;
map_status(?MC_AUTH_CONTINUE) ->
    auth_continue.


-spec process_error_response(any()) ->
                                    mc_error().
process_error_response({ok, #mc_header{status=Status}, #mc_entry{data=Msg},
                        _NCB}) ->
    {memcached_error, map_status(Status), Msg}.

% -------------------------------------------------

%% TODO make these work with simulator
-ifdef(nothing).

blank_he() ->
    {#mc_header{}, #mc_entry{}}.

noop_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E, undefined} = cmd(?NOOP, Sock, undefined, undefined, blank_he()),
    ok = gen_tcp:close(Sock).

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    ok = gen_tcp:close(Sock).

flush_test_sock(Sock) ->
    {ok, _H, _E, undefined} = cmd(?FLUSH, Sock, undefined, undefined, blank_he()).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    flush_test_sock(Sock),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?SET, Sock, undefined, undefined,
                                      {#mc_header{},
                                       #mc_entry{key = Key, data = <<"AAA">>}}),
        get_test_match(Sock, Key, <<"AAA">>)
    end)().

get_test_match(Sock, Key, Data) ->
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, _H, E, _S} = cmd(?GETK, Sock,
                      fun (_H, E, _S) ->
                              ets:update_counter(D, nvals, 1),
                              ?assertMatch(Key, E#mc_entry.key),
                              ?assertMatch(Data, E#mc_entry.data)
                      end, undefined,
                      {#mc_header{}, #mc_entry{key = Key}}),
    ?assertMatch(Key, E#mc_entry.key),
    ?assertMatch(Data, E#mc_entry.data),
    ?assertMatch([{nvals, 1}], ets:lookup(D, nvals)).

get_miss_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    {ok, H, _E, ok} = cmd(?GET, Sock, fun (_H, _E, _CD) -> ok end, undefined,
                          {#mc_header{}, #mc_entry{key = <<"not_a_key">>}}),
    ?assert(H#mc_header.status =/= ?SUCCESS),
    ok = gen_tcp:close(Sock).

getk_miss_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    {ok, H, _E, ok} = cmd(?GETK, Sock, fun (_H, _E, undefined) -> ok end, undefined,
                          {#mc_header{}, #mc_entry{key = <<"not_a_key">>}}),
    ?assert(H#mc_header.status =/= ?SUCCESS),
    ok = gen_tcp:close(Sock).

arith_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    Key = <<"a">>,
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?SET, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = <<"1">>}}),
        get_test_match(Sock, Key, <<"1">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?INCREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"2">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?INCREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"3">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?INCREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 10}}),
        get_test_match(Sock, Key, <<"13">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?DECREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"12">>),
        ok
    end)(),
    ok = gen_tcp:close(Sock).

stats_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, _H, _E, _C} = cmd(?STAT, Sock,
                                  fun (_MH, _ME, _CD) ->
                                          ets:update_counter(D, nvals, 1)
                                  end, undefined,
                                  {#mc_header{}, #mc_entry{}}),
    [{nvals, X}] = ets:lookup(D, nvals),
    ?assert(X > 0),
    ok = gen_tcp:close(Sock).

second_stats_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E, Stats} = cmd(?STAT, Sock,
                              fun (_MH, ME, CD) ->
                                      dict:store(ME#mc_entry.key,
                                                 ME#mc_entry.data,
                                                 CD)
                              end,
                              dict:new(),
                              {#mc_header{}, #mc_entry{}}),
    ?assert(dict:size(Stats) > 0),
    ok = gen_tcp:close(Sock).

stats_subcommand_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E, Stats} = cmd(?STAT, Sock,
                              fun (_MH, ME, CD) ->
                                      dict:store(ME#mc_entry.key,
                                                 ME#mc_entry.data,
                                                 CD)
                              end,
                              dict:new(),
                              {#mc_header{}, #mc_entry{key = <<"settings">>}}),
    ?assert(dict:size(Stats) > 0),
    ok = gen_tcp:close(Sock).

-endif.

%% seeks Item in sorted list turned into tuple in indices [L, R)
tuple_binary_search(_Item, _Tuple, L, R) when L >= R ->
    false;
tuple_binary_search(Item, Tuple, L, R) ->
    X = (L + R) div 2,
    Candidate = erlang:element(X, Tuple),
    if
        Candidate =:= Item -> true;
        true ->
            if
                Candidate < Item -> tuple_binary_search(Item, Tuple, X+1, R);
                true -> tuple_binary_search(Item, Tuple, L, X)
            end
    end.

mk_get_zero_open_checkpoint_vbuckets_checker(StatNamesTuple) ->
    fun (Key, ValueBin, Acc) ->
            case ValueBin =:= <<"0">>
                andalso tuple_binary_search(Key, StatNamesTuple, 1, erlang:size(StatNamesTuple)+1) of
                true ->
                  case misc:split_binary_at_char(Key, $:) of
                      {<<"vb_", VB/binary>>, <<"open_checkpoint_id">>} ->
                          [list_to_integer(binary_to_list(VB)) | Acc]
                  end;
                false ->
                    Acc
            end
    end.


get_zero_open_checkpoint_vbuckets(Upstream, VBuckets) ->
    StatNames = [iolist_to_binary([<<"vb_">>, integer_to_list(VBucket), <<":open_checkpoint_id">>])
                 || VBucket <- VBuckets],
    StatNamesTuple = erlang:list_to_tuple(lists:sort(StatNames)),
    mc_binary:quick_stats(Upstream, <<"checkpoint">>,
                          mk_get_zero_open_checkpoint_vbuckets_checker(StatNamesTuple), []).

build_sync_flags(Key, VBucket, CAS) ->
    <<
     0:16/big, % Reserved
     0:8/big,  % Reserved
     0:4/big,  % Replica Count
     1:1/big,  % Persistence
     0:1/big,  % Mutation
     0:1/big,  % R + P
     0:1/big,  % Reserved
     1:16/big, % Number of keyspecs to follow
     CAS:64/big, % CAS
     VBucket:16/big,
     (erlang:size(Key)):16/big,
     Key/binary
     >>.
