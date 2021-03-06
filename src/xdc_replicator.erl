%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

%% XDC Replicator Functions
-module(xdc_replicator).
-behaviour(gen_server).

%% public functions
-export([cancel_replication/1]).
-export([async_replicate/1]).
-export([update_task/1]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([start_db_compaction_notifier/2, stop_db_compaction_notifier/1]).

-include("xdc_replicator.hrl").

%% public functions
cancel_replication({BaseId, Extension}) ->
    FullRepId = BaseId ++ Extension,
    ?xdcr_info("Canceling replication `~s`...", [FullRepId]),
    case supervisor:terminate_child(xdc_rep_sup, FullRepId) of
        ok ->
            ?xdcr_info("Replication `~s` canceled.", [FullRepId]),
            case supervisor:delete_child(xdc_rep_sup, FullRepId) of
                ok ->
                    {ok, {cancelled, ?l2b(FullRepId)}};
                {error, not_found} ->
                    {ok, {cancelled, ?l2b(FullRepId)}};
                Error ->
                    Error
            end;
        Error ->
            ?xdcr_error("Error canceling replication `~s`: ~p", [FullRepId, Error]),
            Error
    end.

async_replicate(#rep{id = {BaseId, Ext}, source = Src, target = Tgt} = Rep) ->
    RepChildId = BaseId ++ Ext,
    Source = couch_api_wrap:db_uri(Src),
    Target = couch_api_wrap:db_uri(Tgt),
    Timeout = get_value(connection_timeout, Rep#rep.options),
    ChildSpec = {
      RepChildId,
      {gen_server, start_link, [?MODULE, Rep, [{timeout, Timeout}]]},
      temporary,
      1,
      worker,
      [?MODULE]
     },
    %% All these nested cases to attempt starting/restarting a replication child
    %% are ugly and not 100%% race condition free. The following patch submission
    %% is a solution:
    %%
    %% http://erlang.2086793.n4.nabble.com/PATCH-supervisor-atomically-delete-child-spec-when-child-terminates-td3226098.html
    %%
    ?xdcr_info("try to start new replication `~s` (`~s` -> `~s`)",
               [RepChildId, Source, Target]),
    case supervisor:start_child(xdc_rep_sup, ChildSpec) of
        {ok, Pid} ->
            ?xdcr_info("starting new replication `~s` at ~p (`~s` -> `~s`)",
                       [RepChildId, Pid, Source, Target]),
            {ok, Pid};
        {error, already_present} ->
            case supervisor:restart_child(xdc_rep_sup, RepChildId) of
                {ok, Pid} ->
                    ?xdcr_info("restarting replication `~s` at ~p (`~s` -> `~s`)",
                               [RepChildId, Pid, Source, Target]),
                    {ok, Pid};
                {error, running} ->
                    %% this error occurs if multiple replicators are racing
                    %% each other to start and somebody else won. Just grab
                    %% the Pid by calling start_child again.
                    {error, {already_started, Pid}} =
                        supervisor:start_child(xdc_rep_sup, ChildSpec),
                    ?xdcr_info("replication `~s` already running at ~p (`~s` -> `~s`)",
                               [RepChildId, Pid, Source, Target]),
                    {ok, Pid};
                {error, {'EXIT', {badarg,
                                  [{erlang, apply, [gen_server, start_link, undefined]} | _]}}} ->
                    %% Clause to deal with a change in the supervisor module introduced
                    %% in R14B02. For more details consult the thread at:
                    %%     http://erlang.org/pipermail/erlang-bugs/2011-March/002273.html
                    _ = supervisor:delete_child(xdc_rep_sup, RepChildId),
                    async_replicate(Rep);
                {error, _} = Error ->
                    Error
            end;
        {error, {already_started, Pid}} ->
            ?xdcr_info("replication `~s` already running at ~p (`~s` -> `~s`)",
                       [RepChildId, Pid, Source, Target]),
            {ok, Pid};
        {error, {Error, _}} ->
            {error, Error}
    end.


%% gen_server behavior callback functions
init(InitArgs) ->
    try
        do_init(InitArgs)
    catch
        throw:{unauthorized, DbUri} ->
            {stop, {unauthorized,
                    <<"unauthorized to access or create database ", DbUri/binary>>}};
        throw:{db_not_found, DbUri} ->
            {stop, {db_not_found, <<"could not open ", DbUri/binary>>}};
        throw:Error ->
            {stop, Error}
    end.

do_init(#rep{options = Options, id = {BaseId, Ext}} = Rep) ->
    process_flag(trap_exit, true),

    #rep_state{
                source = Source,
                target = Target,
                source_name = SourceName,
                target_name = TargetName,
                start_seq = {_Ts, StartSeq},
                source_seq = SourceCurSeq,
                committed_seq = {_, CommittedSeq}
              } = State = init_state(Rep),

    NumWorkers = get_value(worker_processes, Options),
    BatchSize = get_value(worker_batch_size, Options),
    {ok, ChangesQueue} = couch_work_queue:new([
                                               {max_items, BatchSize * NumWorkers * 2},
                                               {max_size, 100 * 1024 * NumWorkers}
                                              ]),
    %% This starts the _changes reader process. It adds the changes from
    %% the source db to the ChangesQueue.
    ChangesReader = spawn_changes_reader(StartSeq, Source, ChangesQueue, Options),
    %% Changes manager - responsible for dequeing batches from the changes queue
    %% and deliver them to the worker processes.
    ChangesManager = spawn_changes_manager(self(), ChangesQueue, BatchSize),
    %% This starts the worker processes. They ask the changes queue manager for a
    %% a batch of _changes rows to process -> check which revs are missing in the
    %% target, and for the missing ones, it copies them from the source to the target.
    MaxConns = get_value(http_connections, Options),

    ?xdcr_info("changes reader process (PID: ~p) and manager process (PID: ~p) "
               "created, now starting worker processes...",
               [ChangesReader, ChangesManager]),

    Workers = lists:map(
                fun(_) ->
                        {ok, Pid} = xdc_replicator_worker:start_link(
                                      self(), Source, Target, ChangesManager, MaxConns),
                        Pid
                end,
                lists:seq(1, NumWorkers)),

    couch_task_status:add_task([
                                {type, replication},
                                {replication_id, ?l2b(BaseId ++ Ext)},
                                {source, ?l2b(SourceName)},
                                {target, ?l2b(TargetName)},
                                {continuous, get_value(continuous, Options, false)},
                                {revisions_checked, 0},
                                {missing_revisions_found, 0},
                                {docs_read, 0},
                                {docs_written, 0},
                                {doc_write_failures, 0},
                                {source_seq, SourceCurSeq},
                                {checkpointed_source_seq, CommittedSeq},
                                {progress, 0}
                               ]),
    couch_task_status:set_update_frequency(1000),

    %% Until OTP R14B03:
    %%
    %% Restarting a temporary supervised child implies that the original arguments
    %% (#rep{} record) specified in the MFA component of the supervisor
    %% child spec will always be used whenever the child is restarted.
    %% This implies the same replication performance tunning parameters will
    %% always be used. The solution is to delete the child spec (see
    %% cancel_replication/1) and then start the replication again, but this is
    %% unfortunately not immune to race conditions.

    ?xdcr_info("Replication `~p` is using:~n"
               "~c~p worker processes~n"
               "~ca worker batch size of ~p~n"
               "~c~p HTTP connections~n"
               "~ca connection timeout of ~p milliseconds~n"
               "~c~p retries per request~n"
               "~csocket options are: ~s~s",
               [BaseId ++ Ext, $\t, NumWorkers, $\t, BatchSize, $\t,
                MaxConns, $\t, get_value(connection_timeout, Options),
                $\t, get_value(retries, Options),
                $\t, io_lib:format("~p", [get_value(socket_options, Options)]),
                case StartSeq of
                    ?LOWEST_SEQ ->
                        "";
                    _ ->
                        io_lib:format("~n~csource start sequence ~p", [$\t, StartSeq])
                end]),

    ?xdcr_debug("Worker pids are: ~p", [Workers]),

    {ok, State#rep_state{
           changes_queue = ChangesQueue,
           changes_manager = ChangesManager,
           changes_reader = ChangesReader,
           workers = Workers
          }
    }.


handle_info({'DOWN', Ref, _, _, Why}, #rep_state{source_monitor = Ref} = St) ->
    ?xdcr_error("Source database is down. Reason: ~p", [Why]),
    {stop, source_db_down, St};

handle_info({'DOWN', Ref, _, _, Why}, #rep_state{target_monitor = Ref} = St) ->
    ?xdcr_error("Target database is down. Reason: ~p", [Why]),
    {stop, target_db_down, St};

handle_info({'DOWN', Ref, _, _, Why}, #rep_state{src_master_db_monitor = Ref} = St) ->
    ?xdcr_error("Source master database is down. Reason: ~p", [Why]),
    {stop, src_master_db_down, St};

handle_info({'DOWN', Ref, _, _, Why}, #rep_state{tgt_master_db_monitor = Ref} = St) ->
    ?xdcr_error("Target master database is down. Reason: ~p", [Why]),
    {stop, tgt_master_db_down, St};

handle_info({'EXIT', Pid, normal}, #rep_state{changes_reader=Pid} = State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #rep_state{changes_reader=Pid} = State) ->
    ?xdcr_error("ChangesReader process died with reason: ~p", [Reason]),
    {stop, changes_reader_died, xdc_replicator_ckpt:cancel_timer(State)};

handle_info({'EXIT', Pid, normal}, #rep_state{changes_manager = Pid} = State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #rep_state{changes_manager = Pid} = State) ->
    ?xdcr_error("ChangesManager process died with reason: ~p", [Reason]),
    {stop, changes_manager_died, xdc_replicator_ckpt:cancel_timer(State)};

handle_info({'EXIT', Pid, normal}, #rep_state{changes_queue=Pid} = State) ->
    {noreply, State};

handle_info({'EXIT', Pid, Reason}, #rep_state{changes_queue=Pid} = State) ->
    ?xdcr_error("ChangesQueue process died with reason: ~p", [Reason]),
    {stop, changes_queue_died, xdc_replicator_ckpt:cancel_timer(State)};

handle_info({'EXIT', Pid, normal}, #rep_state{workers = Workers} = State) ->
    case Workers -- [Pid] of
        Workers ->
            {stop, {unknown_process_died, Pid, normal}, State};
        [] ->
            catch unlink(State#rep_state.changes_manager),
            catch exit(State#rep_state.changes_manager, kill),
            xdc_replicator_ckpt:do_last_checkpoint(State);
        Workers2 ->
            {noreply, State#rep_state{workers = Workers2}}
    end;

handle_info({'EXIT', Pid, Reason}, #rep_state{workers = Workers} = State) ->
    State2 = xdc_replicator_ckpt:cancel_timer(State),
    case lists:member(Pid, Workers) of
        false ->
            {stop, {unknown_process_died, Pid, Reason}, State2};
        true ->
            ?xdcr_error("Worker ~p died with reason: ~p", [Pid, Reason]),
            {stop, {worker_died, Pid, Reason}, State2}
    end.

handle_call({add_stats, Stats}, From, State) ->
    gen_server:reply(From, ok),
    NewStats = xdc_rep_utils:sum_stats(State#rep_state.stats, Stats),
    {noreply, State#rep_state{stats = NewStats}};

handle_call({report_seq_done, Seq, StatsInc}, From,
            #rep_state{seqs_in_progress = SeqsInProgress, highest_seq_done = HighestDone,
                       current_through_seq = ThroughSeq, stats = Stats} = State) ->
    gen_server:reply(From, ok),
    {NewThroughSeq0, NewSeqsInProgress} = case SeqsInProgress of
                                              [Seq | Rest] ->
                                                  {Seq, Rest};
                                              [_ | _] ->
                                                  {ThroughSeq, ordsets:del_element(Seq, SeqsInProgress)}
                                          end,
    NewHighestDone = lists:max([HighestDone, Seq]),
    NewThroughSeq = case NewSeqsInProgress of
                        [] ->
                            lists:max([NewThroughSeq0, NewHighestDone]);
                        _ ->
                            NewThroughSeq0
                    end,
    ?xdcr_debug("Worker reported seq ~p, through seq was ~p, "
                "new through seq is ~p, highest seq done was ~p, "
                "new highest seq done is ~p~n"
                "Seqs in progress were: ~p~nSeqs in progress are now: ~p",
                [Seq, ThroughSeq, NewThroughSeq, HighestDone,
                 NewHighestDone, SeqsInProgress, NewSeqsInProgress]),
    SourceCurSeq = source_cur_seq(State),
    NewState = State#rep_state{
                 stats = xdc_rep_utils:sum_stats(Stats, StatsInc),
                 current_through_seq = NewThroughSeq,
                 seqs_in_progress = NewSeqsInProgress,
                 highest_seq_done = NewHighestDone,
                 source_seq = SourceCurSeq
                },
    update_task(NewState),
    {noreply, NewState}.


handle_cast({db_compacted, DbName},
            #rep_state{source = #db{name = DbName} = Source} = State) ->
    {ok, NewSource} = couch_db:reopen(Source),
    {noreply, State#rep_state{source = NewSource}};

handle_cast({db_compacted, DbName},
            #rep_state{target = #db{name = DbName} = Target} = State) ->
    {ok, NewTarget} = couch_db:reopen(Target),
    {noreply, State#rep_state{target = NewTarget}};

handle_cast({db_compacted, DbName},
            #rep_state{src_master_db = #db{name = DbName} = SrcMasterDb} = State) ->
    {ok, NewSrcMasterDb} = couch_db:reopen(SrcMasterDb),
    {noreply, State#rep_state{src_master_db = NewSrcMasterDb}};

handle_cast(checkpoint, State) ->
    case xdc_replicator_ckpt:do_checkpoint(State) of
        {ok, NewState} ->
            {noreply, NewState#rep_state{timer = xdc_replicator_ckpt:start_timer(State)}};
        Error ->
            {stop, Error, State}
    end;

handle_cast({report_seq, Seq},
            #rep_state{seqs_in_progress = SeqsInProgress} = State) ->
    NewSeqsInProgress = ordsets:add_element(Seq, SeqsInProgress),
    {noreply, State#rep_state{seqs_in_progress = NewSeqsInProgress}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, #rep_state{rep_details = #rep{id = RepId} = _Rep,
                             checkpoint_history = CheckpointHistory} = State) ->
    terminate_cleanup(State),
    xdc_rep_notifier:notify({finished, RepId, CheckpointHistory});

terminate(shutdown, #rep_state{rep_details = #rep{id = RepId}} = State) ->
    %% cancelled replication throught ?MODULE:cancel_replication/1
    xdc_rep_notifier:notify({error, RepId, <<"cancelled">>}),
    terminate_cleanup(State);

terminate(Reason, State) ->
    #rep_state{
           source_name = Source,
           target_name = Target,
           rep_details = #rep{id = {BaseId, Ext} = RepId} = _Rep
          } = State,
    ?xdcr_error("Replication `~s` (`~s` -> `~s`) failed: ~s",
                [BaseId ++ Ext, Source, Target, to_binary(Reason)]),
    terminate_cleanup(State),
    xdc_rep_notifier:notify({error, RepId, Reason}).

terminate_cleanup(State) ->
    update_task(State),
    stop_db_compaction_notifier(State#rep_state.source_db_compaction_notifier),
    stop_db_compaction_notifier(State#rep_state.target_db_compaction_notifier),
    couch_api_wrap:db_close(State#rep_state.source),
    couch_api_wrap:db_close(State#rep_state.target),
    couch_api_wrap:db_close(State#rep_state.src_master_db),
    couch_api_wrap:db_close(State#rep_state.tgt_master_db).


%% internal helper functions
init_state(Rep) ->
    #rep{
          source = Src, target = Tgt,
          options = Options, user_ctx = UserCtx
        } = Rep,
    {ok, Source} = couch_api_wrap:db_open(Src, [{user_ctx, UserCtx}]),
    {ok, Target} = couch_api_wrap:db_open(Tgt, [{user_ctx, UserCtx}],
                                          get_value(create_target, Options, false)),

    {ok, SourceInfo} = couch_api_wrap:get_db_info(Source),
    {ok, TargetInfo} = couch_api_wrap:get_db_info(Target),

    {ok, SrcMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Source),
                          [{user_ctx, UserCtx}]),
    {ok, TgtMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Target),
                          [{user_ctx, UserCtx}]),

    %% We have to pass the vbucket database along with the master database
    %% because the replication log id needs to be prefixed with the vbucket id
    %% at both the source and the destination.
    [SourceLog, TargetLog] = find_replication_logs(
                               [{Source, SrcMasterDb}, {Target, TgtMasterDb}],
                               Rep),

    {StartSeq0, History} = compare_replication_logs(SourceLog, TargetLog),
    StartSeq1 = get_value(since_seq, Options, StartSeq0),
    StartSeq = {0, StartSeq1},
    #doc{body={CheckpointHistory}} = SourceLog,
    State = #rep_state{
      rep_details = Rep,
      source_name = couch_api_wrap:db_uri(Source),
      target_name = couch_api_wrap:db_uri(Target),
      source = Source,
      target = Target,
      src_master_db = SrcMasterDb,
      tgt_master_db = TgtMasterDb,
      history = History,
      checkpoint_history = {[{<<"no_changes">>, true}| CheckpointHistory]},
      start_seq = StartSeq,
      current_through_seq = StartSeq,
      committed_seq = StartSeq,
      source_log = SourceLog,
      target_log = TargetLog,
      rep_starttime = httpd_util:rfc1123_date(),
      src_starttime = get_value(<<"instance_start_time">>, SourceInfo),
      tgt_starttime = get_value(<<"instance_start_time">>, TargetInfo),
      session_id = couch_uuids:random(),
      source_db_compaction_notifier =
          start_db_compaction_notifier(Source, self()),
      target_db_compaction_notifier =
          start_db_compaction_notifier(Target, self()),
      source_monitor = db_monitor(Source),
      target_monitor = db_monitor(Target),
      src_master_db_monitor = db_monitor(SrcMasterDb),
      tgt_master_db_monitor = db_monitor(TgtMasterDb),
      source_seq = get_value(<<"update_seq">>, SourceInfo, ?LOWEST_SEQ)
     },
    State#rep_state{timer = xdc_replicator_ckpt:start_timer(State)}.


spawn_changes_reader(StartSeq, #httpdb{} = Db, ChangesQueue, Options) ->
    spawn_link(fun() ->
                       put(last_seq, StartSeq),
                       put(retries_left, Db#httpdb.retries),
                       read_changes(StartSeq, Db#httpdb{retries = 0}, ChangesQueue, Options)
               end);
spawn_changes_reader(StartSeq, Db, ChangesQueue, Options) ->
    spawn_link(fun() ->
                       read_changes(StartSeq, Db, ChangesQueue, Options)
               end).

read_changes(StartSeq, Db, ChangesQueue, Options) ->
    try
        couch_api_wrap:changes_since(Db, all_docs, StartSeq,
                                     fun(#doc_info{local_seq = Seq, id = Id} = DocInfo) ->
                                             case Id of
                                                 <<>> ->
                                                     %% Previous CouchDB releases had a bug which allowed a doc
                                                     %% with an empty ID to be inserted into databases. Such doc
                                                     %% is impossible to GET.
                                                     ?xdcr_error("Replicator: ignoring document with empty ID in "
                                                                 "source database `~s` (_changes sequence ~p)",
                                                                 [couch_api_wrap:db_uri(Db), Seq]);
                                                 _ ->
                                                     ok = couch_work_queue:queue(ChangesQueue, DocInfo)
                                             end,
                                             put(last_seq, Seq)
                                     end, Options),
        couch_work_queue:close(ChangesQueue)
    catch exit:{http_request_failed, _, _, _} = Error ->
            case get(retries_left) of
                N when N > 0 ->
                    put(retries_left, N - 1),
                    LastSeq = get(last_seq),
                    Db2 = case LastSeq of
                              StartSeq ->
                                  ?xdcr_info("Retrying _changes request to source database ~s"
                                             " with since=~p in ~p seconds",
                                             [couch_api_wrap:db_uri(Db), LastSeq, Db#httpdb.wait / 1000]),
                                  ok = timer:sleep(Db#httpdb.wait),
                                  Db#httpdb{wait = 2 * Db#httpdb.wait};
                              _ ->
                                  ?xdcr_info("Retrying _changes request to source database ~s"
                                             " with since=~p", [couch_api_wrap:db_uri(Db), LastSeq]),
                                  Db
                          end,
                    read_changes(LastSeq, Db2, ChangesQueue, Options);
                _ ->
                    exit(Error)
            end
    end.


spawn_changes_manager(Parent, ChangesQueue, BatchSize) ->
    spawn_link(fun() ->
                       changes_manager_loop_open(Parent, ChangesQueue, BatchSize, 1)
               end).

changes_manager_loop_open(Parent, ChangesQueue, BatchSize, Ts) ->
    receive
        {get_changes, From} ->
            case couch_work_queue:dequeue(ChangesQueue, BatchSize) of
                closed ->
                    From ! {closed, self()};
                {ok, Changes, _Size} ->
                    #doc_info{local_seq = Seq} = lists:last(Changes),
                    ReportSeq = {Ts, Seq},
                    ok = gen_server:cast(Parent, {report_seq, ReportSeq}),
                    From ! {changes, self(), Changes, ReportSeq}
            end,
            changes_manager_loop_open(Parent, ChangesQueue, BatchSize, Ts + 1)
    end.

find_replication_logs(DbList, #rep{id = {BaseId, _}} = Rep) ->
    fold_replication_logs(DbList, ?REP_ID_VERSION, BaseId, BaseId, Rep, []).


fold_replication_logs([], _Vsn, _LogId, _NewId, _Rep, Acc) ->
    lists:reverse(Acc);

fold_replication_logs([{Db, MasterDb} | Rest] = Dbs, Vsn, LogId0, NewId0, Rep, Acc) ->
    LogId = xdc_rep_utils:get_checkpoint_log_id(Db, LogId0),
    NewId = xdc_rep_utils:get_checkpoint_log_id(Db, NewId0),
    case couch_api_wrap:open_doc(MasterDb, LogId, [ejson_body]) of
        {error, <<"not_found">>} when Vsn > 1 ->
            OldRepId = xdc_rep_utils:replication_id(Rep, Vsn - 1),
            fold_replication_logs(Dbs, Vsn - 1,
                                  ?l2b(OldRepId), NewId0, Rep, Acc);
        {error, <<"not_found">>} ->
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [#doc{id = NewId, body = {[]}} | Acc]);
        {ok, Doc} when LogId =:= NewId ->
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [Doc | Acc]);
        {ok, Doc} ->
            MigratedLog = #doc{id = NewId, body = Doc#doc.body},
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [MigratedLog | Acc])
    end.

compare_replication_logs(SrcDoc, TgtDoc) ->
    #doc{body={RepRecProps}} = SrcDoc,
    #doc{body={RepRecPropsTgt}} = TgtDoc,
    case get_value(<<"session_id">>, RepRecProps) ==
        get_value(<<"session_id">>, RepRecPropsTgt) of
        true ->
            %% if the records have the same session id,
            %% then we have a valid replication history
            OldSeqNum = get_value(<<"source_last_seq">>, RepRecProps, ?LOWEST_SEQ),
            OldHistory = get_value(<<"history">>, RepRecProps, []),
            {OldSeqNum, OldHistory};
        false ->
            SourceHistory = get_value(<<"history">>, RepRecProps, []),
            TargetHistory = get_value(<<"history">>, RepRecPropsTgt, []),
            ?xdcr_info("Replication records differ. "
                       "Scanning histories to find a common ancestor.", []),
            ?xdcr_debug("Record on source:~p~nRecord on target:~p~n",
                        [RepRecProps, RepRecPropsTgt]),
            compare_rep_history(SourceHistory, TargetHistory)
    end.

start_db_compaction_notifier(#db{name = DbName}, Server) ->
    {ok, Notifier} = couch_db_update_notifier:start_link(
                       fun({compacted, DbName1}) when DbName1 =:= DbName ->
                               ok = gen_server:cast(Server, {db_compacted, DbName});
                          (_) ->
                               ok
                       end),
    Notifier;
start_db_compaction_notifier(_, _) ->
    nil.

stop_db_compaction_notifier(nil) ->
    ok;
stop_db_compaction_notifier(Notifier) ->
    couch_db_update_notifier:stop(Notifier).

db_monitor(#db{} = Db) ->
    couch_db:monitor(Db);
db_monitor(_HttpDb) ->
    nil.

compare_rep_history(S, T) when S =:= [] orelse T =:= [] ->
    ?xdcr_info("no common ancestry -- performing full replication", []),
    {?LOWEST_SEQ, []};
compare_rep_history([{S} | SourceRest], [{T} | TargetRest] = Target) ->
    SourceId = get_value(<<"session_id">>, S),
    case has_session_id(SourceId, Target) of
        true ->
            RecordSeqNum = get_value(<<"recorded_seq">>, S, ?LOWEST_SEQ),
            ?xdcr_info("found a common replication record with source_seq ~p",
                       [RecordSeqNum]),
            {RecordSeqNum, SourceRest};
        false ->
            TargetId = get_value(<<"session_id">>, T),
            case has_session_id(TargetId, SourceRest) of
                true ->
                    RecordSeqNum = get_value(<<"recorded_seq">>, T, ?LOWEST_SEQ),
                    ?xdcr_info("found a common replication record with source_seq ~p",
                               [RecordSeqNum]),
                    {RecordSeqNum, TargetRest};
                false ->
                    compare_rep_history(SourceRest, TargetRest)
            end
    end.

has_session_id(_SessionId, []) ->
    false;
has_session_id(SessionId, [{Props} | Rest]) ->
    case get_value(<<"session_id">>, Props, nil) of
        SessionId ->
            true;
        _Else ->
            has_session_id(SessionId, Rest)
    end.

source_cur_seq(#rep_state{source = #httpdb{} = Db, source_seq = Seq}) ->
    case (catch couch_api_wrap:get_db_info(Db#httpdb{retries = 3})) of
        {ok, Info} ->
            get_value(<<"update_seq">>, Info, Seq);
        _ ->
            Seq
    end;
source_cur_seq(#rep_state{source = Db, source_seq = Seq}) ->
    {ok, Info} = couch_api_wrap:get_db_info(Db),
    get_value(<<"update_seq">>, Info, Seq).


update_task(State) ->
    #rep_state{
             current_through_seq = {_, CurSeq},
             committed_seq = {_, CommittedSeq},
             source_seq = SourceCurSeq,
             stats = Stats
            } = State,
    couch_task_status:update([
                              {revisions_checked, Stats#rep_stats.missing_checked},
                              {missing_revisions_found, Stats#rep_stats.missing_found},
                              {docs_read, Stats#rep_stats.docs_read},
                              {docs_written, Stats#rep_stats.docs_written},
                              {doc_write_failures, Stats#rep_stats.doc_write_failures},
                              {source_seq, SourceCurSeq},
                              {checkpointed_source_seq, CommittedSeq},
                              case is_number(CurSeq) andalso is_number(SourceCurSeq) of
                                  true ->
                                      case SourceCurSeq of
                                          0 ->
                                              {progress, 0};
                                          _ ->
                                              {progress, (CurSeq * 100) div SourceCurSeq}
                                      end;
                                  false ->
                                      {progress, null}
                              end
                             ]).

