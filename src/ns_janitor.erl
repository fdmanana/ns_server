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
%% Monitor and maintain the vbucket layout of each bucket.
%%
-module(ns_janitor).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([cleanup/2, current_states/2, stop_rebalance_status/1]).

-define(WAIT_FOR_MEMCACHED_TRIES, 5).

-spec cleanup(string(), list()) -> ok | {error, wait_for_memcached_failed}.
cleanup(Bucket, Options) ->
    {ok, Config} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(Config) of
        membase -> do_cleanup(Bucket, Options, Config);
        _ -> ok
    end.

do_cleanup(Bucket, Options, Config) ->
    {Map, Servers} =
        case proplists:get_value(map, Config) of
            X when X == undefined; X == [] ->
                S = ns_cluster_membership:active_nodes(),
                Config1 = lists:keystore(servers, 1, Config, {servers, S}),
                NumVBuckets = proplists:get_value(num_vbuckets, Config1),
                NumReplicas = ns_bucket:num_replicas(Config1),
                ns_bucket:set_bucket_config(Bucket, Config1),
                wait_for_memcached(S, Bucket, up),
                NewMap = case ns_janitor_map_recoverer:read_existing_map(Bucket, S, NumVBuckets, NumReplicas) of
                             {ok, M} ->
                                 M;
                             {error, no_map} ->
                                 ns_rebalancer:generate_initial_map(Config1)
                         end,

                Config2 = lists:keystore(map, 1, Config1, {map, NewMap}),
                ns_bucket:set_bucket_config(Bucket, Config2),

                MapOptions = ns_bucket:config_to_map_options(Config2),
                case ns_rebalancer:unbalanced(NewMap, S) of
                    false ->
                        ns_bucket:update_vbucket_map_history(NewMap, MapOptions);
                    true ->
                        ok
                end,
                {NewMap, S};
            M ->
                {M, proplists:get_value(servers, Config)}
        end,
    case Servers of
        [] -> ok;
        _ ->
            case {wait_for_memcached(Servers, Bucket, connected, proplists:get_value(timeout, Options, 5)),
                  proplists:get_bool(best_effort, Options)} of
                {[_|_] = Down, false} ->
                    ?log_error("Bucket ~p not yet ready on ~p", [Bucket, Down]),
                    {error, wait_for_memcached_failed};
                {Down, _} ->
                    ReadyServers = ordsets:subtract(lists:sort(Servers),
                                                    lists:sort(Down)),
                    FFMap = case proplists:get_value(fastForwardMap, Config) of
                                undefined -> [];
                                FFMap0 ->
                                    case FFMap0 =:= [] orelse length(FFMap0) =:= length(Map) of
                                        true ->
                                            FFMap0;
                                        false ->
                                            ?log_warning("fast forward map length doesn't match map length. Ignoring it"),
                                            []
                                    end
                            end,
                    Map1 =
                        case sanify(Bucket, Map, FFMap, ReadyServers, Down) of
                            Map -> Map;
                            MapNew ->
                                ns_bucket:set_map(Bucket, MapNew),
                                MapNew
                        end,
                    Replicas = ns_bucket:map_to_replicas(Map1),

                    cb_replication:maybe_switch_replication_mode(Bucket),

                    Nodes =
                        case cb_replication:get_mode(Bucket) of
                            new ->
                                %% change replication on nodes that are bucket
                                %% members
                                %%
                                %% NOTE: other nodes that are part of cluster
                                %% will shutdown bucket supervisors
                                %% themselfes. We don't need to touch them
                                %% here because replication is pull. And we
                                %% don't care if some of them are replicating
                                %% from bucket members.
                                Servers;
                            compat ->
                                ns_node_disco:nodes_actual_proper()
                        end,

                    cb_replication:set_replicas(Bucket, Replicas, Nodes),

                    case Down =:= [] andalso proplists:get_bool(consider_stopping_rebalance_status, Options) of
                        true ->
                            maybe_stop_rebalance_status();
                        _ -> ok
                    end,

                    mark_bucket_warmed(Bucket, Servers),

                    ok
            end
    end.

-spec sanify(string(), map(), map(), [atom()], [atom()]) -> map().
sanify(Bucket, Map, FFMap, Servers, DownNodes) ->
    {ok, States, Zombies} = current_states(Servers, Bucket),
    EffectiveFFMap = case FFMap of
                         [] ->
                             [[] || _ <- Map];
                         _ ->
                             FFMap
                     end,
    EnumeratedChains = lists:zip3(lists:seq(0, length(Map)-1),
                                  Map,
                                  EffectiveFFMap),
    [sanify_chain(Bucket, States, Chain, FutureChain, VBucket, Zombies ++ DownNodes)
     || {VBucket, Chain, FutureChain} <- EnumeratedChains].

sanify_chain(Bucket, State, Chain, FutureChain, VBucket, Zombies) ->
    NewChain = do_sanify_chain(Bucket, State, Chain, FutureChain, VBucket, Zombies),
    %% Fill in any missing replicas
    case length(NewChain) < length(Chain) of
        false ->
            NewChain;
        true ->
            NewChain ++ lists:duplicate(length(Chain) - length(NewChain),
                                        undefined)
    end.


do_sanify_chain(Bucket, States, Chain, FutureChain, VBucket, Zombies) ->
    NodeStates = [{N, S} || {N, V, S} <- States, V == VBucket],
    ChainStates = lists:map(fun (N) ->
                                    case lists:keyfind(N, 1, NodeStates) of
                                        false -> {N, case lists:member(N, Zombies) of
                                                         true -> zombie;
                                                         _ -> missing
                                                     end};
                                        X -> X
                                    end
                            end, Chain),
    ExtraStates = [X || X = {N, _} <- NodeStates,
                        not lists:member(N, Chain)],
    case ChainStates of
        [{undefined, _}|_] ->
            Chain;
        [{Master, State}|ReplicaStates] when State /= active andalso State /= zombie ->
            case [N || {N, active} <- ReplicaStates ++ ExtraStates] of
                [] ->
                    %% We'll let the next pass catch the replicas.
                    ?log_info("Setting vbucket ~p in ~p on ~p from ~p to active.",
                              [VBucket, Bucket, Master, State]),
                    ns_memcached:set_vbucket(Master, Bucket, VBucket, active),
                    Chain;
                [Node] ->
                    PickFutureChain =
                        case FutureChain of
                            [Node | _] ->
                                %% if active is future master check rest of future chain
                                [FFMasterState | FFReplicaStates] = [proplists:get_value(N, NodeStates)
                                                                     || N <- FutureChain,
                                                                        N =/= undefined],
                                %% and if everything fits -- cool
                                FFMasterState =:= active
                                    andalso lists:all(fun (replica) -> true;
                                                          (_) -> false
                                                      end, FFReplicaStates);
                            _ ->
                                false
                        end,
                    case PickFutureChain of
                        true ->
                            ?log_warning("Master for vbucket ~p in ~p is not active, but entire fast-forward map chain fits (~p), so using it.", [VBucket, Bucket, FutureChain]),
                            FutureChain;
                        false ->
                            %% One active node, but it's not the master
                            case misc:position(Node, Chain) of
                                false ->
                                    %% It's an extra node
                                    ?log_warning(
                                       "Master for vbucket ~p in ~p is not active, but ~p is, so making that the master.",
                                       [VBucket, Bucket, Node]),
                                    [Node];
                                Pos ->
                                    [Node|lists:nthtail(Pos, Chain)]
                            end
                    end;
                Nodes ->
                    ?log_error(
                      "Extra active nodes ~p for vbucket ~p in ~p. This should never happen!",
                      [Nodes, Bucket, VBucket]),
                    Chain
            end;
        C = [_|ReplicaStates] ->
            %% NOTE: here we know that master is either active or zombie
            lists:foreach(
              fun ({_, {N, active}}) ->
                      ?log_error("Active replica ~p for vbucket ~p in ~p. "
                                 "This should never happen, but we have an "
                                 "active master, so I'm deleting it.",
                                 [N, Bucket]),
                      %% %% cb_replication:stop_replications(N, Bucket, [VBucket]),
                      %%
                      %% was here, but because we're going to call
                      %% set_replicas at the end of janitor pass this is not
                      %% required.
                      ns_memcached:set_vbucket(N, Bucket, VBucket, dead);
                  ({_, {_, replica}})-> % This is what we expect
                      ok;
                  ({_, {_, missing}}) ->
                      %% Either fewer nodes than copies or replicator
                      %% hasn't started yet
                      ok;
                  ({{_, zombie}, _}) -> ok;
                  ({_, {_, zombie}}) -> ok;
                  ({{undefined, _}, _}) -> ok;
                  ({{SrcNode, _}, {DstNode, _}} = Pair) ->
                      ?log_info("Killing replicator from ~p to ~p "
                                "for vbucket ~p because of ~p",
                                [SrcNode, DstNode, VBucket, Pair]),
                      cb_replication:stop_replications(Bucket, SrcNode, DstNode,
                                                       [VBucket])
              end, misc:pairs(C)),
            HaveAllCopies = lists:all(
                              fun ({undefined, _}) -> false;
                                  ({_, replica}) -> true;
                                  (_) -> false
                              end, ReplicaStates),
            lists:foreach(
              fun ({N, State}) ->
                      case {HaveAllCopies, State} of
                          {true, dead} ->
                              ?log_info("Deleting dead vbucket ~p in ~p on ~p",
                                        [VBucket, Bucket, N]),
                              ns_memcached:delete_vbucket(N, Bucket, VBucket);
                          {true, _} ->
                              ?log_info("Deleting vbucket ~p in ~p on ~p",
                                        [VBucket, Bucket, N]),
                              ns_memcached:set_vbucket(
                                N, Bucket, VBucket, dead),
                              ns_memcached:delete_vbucket(N, Bucket, VBucket);
                          {false, dead} ->
                              ok;
                          {false, _} ->
                              ?log_info("Setting vbucket ~p in ~p on ~p from ~p"
                                        " to dead because we don't have all "
                                        "copies~n~p",
                                        [N, Bucket, VBucket,
                                         State, {ChainStates, ExtraStates}]),
                              ns_memcached:set_vbucket(N, Bucket, VBucket, dead)
                      end
              end, ExtraStates),
            Chain
    end.

%% [{Node, VBucket, State}...]
-spec current_states(list(atom()), string()) ->
                            {ok, list({atom(), integer(), atom()}), list(atom())}.
current_states(Nodes, Bucket) ->
    {Replies, DownNodes} = ns_memcached:list_vbuckets_multi(Nodes, Bucket),
    {GoodReplies, BadReplies} = lists:partition(fun ({_, {ok, _}}) -> true;
                                                    (_) -> false
                                                     end, Replies),
    ErrorNodes = [Node || {Node, _} <- BadReplies],
    States = [{Node, VBucket, State} || {Node, {ok, Reply}} <- GoodReplies,
                                        {VBucket, State} <- Reply],
    {ok, States, ErrorNodes ++ DownNodes}.

%%
%% Internal functions
%%

wait_for_memcached(Nodes, Bucket, Type) ->
    wait_for_memcached(Nodes, Bucket, Type, ?WAIT_FOR_MEMCACHED_TRIES).

wait_for_memcached(Nodes, Bucket, Type, Tries) when Tries > 0 ->
    ReadyNodes = ns_memcached:ready_nodes(Nodes, Bucket, Type, default),
    DownNodes = ordsets:subtract(ordsets:from_list(Nodes),
                                 ordsets:from_list(ReadyNodes)),
    case DownNodes of
        [] ->
            [];
        _ ->
            case Tries - 1 of
                0 ->
                    DownNodes;
                X ->
                    ?log_info("Waiting for ~p on ~p", [Bucket, DownNodes]),
                    timer:sleep(1000),
                    wait_for_memcached(Nodes, Bucket, Type, X)
            end
    end.

stop_rebalance_status(Fn) ->
    Sentinel = make_ref(),
    Fun = fun ({rebalance_status, Value}) ->
                  NewValue =
                      case Value of
                          running ->
                              Fn();
                          _ ->
                              Value
                      end,
                  {rebalance_status, NewValue};
              ({rebalancer_pid, _}) ->
                  {rebalancer_pid, undefined};
              (Other) ->
                  Other
          end,

    ok = ns_config:update(Fun, Sentinel).

maybe_stop_rebalance_status() ->
    Status = try ns_orchestrator:rebalance_progress_full()
             catch E:T ->
                     ?log_error("cannot reach orchestrator: ~p:~p", [E,T]),
                     error
             end,
    case Status of
        %% if rebalance is not actually running according to our
        %% orchestrator, we'll consider checking config and seeing if
        %% we should unmark is at not running
        not_running ->
            stop_rebalance_status(
              fun () ->
                      ale:info(?USER_LOGGER,
                               "Resetting rebalance status "
                               "since it's not really running"),
                      {none, <<"Rebalance stopped by janitor.">>}
              end);
        _ ->
            ok
    end.

mark_bucket_warmed(Bucket, Nodes) ->
    {Replies, BadNodes} = ns_memcached:mark_warmed(Nodes, Bucket),
    BadReplies = [{N, R} || {N, R} <- Replies,
                            %% unhandled returned by old nodes
                            R =/= ok andalso R =/= unhandled],

    case {BadReplies, BadNodes} of
        {[], []} ->
            ok;
        {_, _} ->
            ?log_error("Failed to mark bucket `~p` as warmed up."
                       "~nBadNodes:~n~p~nBadReplies:~n~p",
                       [Bucket, BadNodes, BadReplies]),
            {error, BadNodes, BadReplies}
    end.
