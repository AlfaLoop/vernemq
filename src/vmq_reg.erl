%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_reg).
-include("vmq_server.hrl").

%% API
-export([start_link/0,

         %% used in vmq_session fsm handling
         subscribe/4,
         unsubscribe/4,
         register_subscriber/4,
         delete_subscriptions/1,
         %% used in vmq_session fsm handling
         publish/1,

         %% used in vmq_session:get_info/2
         get_session_pids/1,
         get_queue_pid/1,

         %% used in vmq_server_utils
         client_stats/0,
         total_sessions/0,
         total_inactive_sessions/0,
         total_subscriptions/0,
         retained/0,

         stored/1
        ]).

%% gen_server callback
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% used by/through remote calls
-export([migrate_session/2,
         publish/2,
         register_subscriber_/3]).

%% used from plugins
-export([direct_plugin_exports/1]).
%% used by reg views
-export([subscribe_subscriber_changes/0,
         fold_subscribers/2]).
%% used by vmq_session:list_sessions
-export([fold_sessions/2]).

%% might be used for presence support
-export([deliver_all_retained_for_subscriber_id/1]).

%% exported because currently used by netsplit tests
-export([subscriptions_for_subscriber_id/1]).

-record(state, {}).
-record(session, {subscriber_id,
                  queue_pid,
                  monitor,
                  last_seen,
                  balance,
                  clean}).

-type state() :: #state{}.

-define(SUBSCRIBER_DB, {vmq, subscriber}).
-define(TOMBSTONE, '$deleted').

-spec start_link() -> {ok, pid()} | ignore | {error, atom()}.
start_link() ->
    case ets:info(vmq_session) of
        undefined ->
            _ = ets:new(vmq_session, [public,
                                      bag,
                                      named_table,
                                      {keypos, 2},
                                      {read_concurrency, true}]);
        _ ->
            %% ets table already exists, we'll remap the monitors
            %% in the init callback.
            ignore
    end,
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec subscribe(flag(), username() | plugin_id(), subscriber_id(),
                [{topic(), qos()}]) -> ok | {error, not_allowed
                                             | overloaded
                                             | not_ready}.

subscribe(false, User, SubscriberId, Topics) ->
    %% trade availability for consistency
    vmq_cluster:if_ready(fun subscribe_/3, [User, SubscriberId, Topics]);
subscribe(true, User, SubscriberId, Topics) ->
    %% trade consistency for availability
    subscribe_(User, SubscriberId, Topics).

subscribe_(User, SubscriberId, Topics) ->
    case vmq_plugin:all_till_ok(auth_on_subscribe,
                                [User, SubscriberId, Topics]) of
        ok ->
            subscribe_op(User, SubscriberId, Topics);
        {ok, NewTopics} when is_list(NewTopics) ->
            subscribe_op(User, SubscriberId, NewTopics);
        {error, _} ->
            {error, not_allowed}
    end.

subscribe_op(User, SubscriberId, Topics) ->
    rate_limited_op(
      fun() ->
              add_subscriber(Topics, SubscriberId)
      end,
      fun(_) ->
              QPid = get_queue_pid(SubscriberId),
              _ = [begin
                       _ = vmq_exo:incr_subscription_count(),
                       deliver_retained(SubscriberId, QPid, T, QoS)
                   end || {T, QoS} <- Topics],
              vmq_plugin:all(on_subscribe, [User, SubscriberId, Topics]),
              ok
      end).

-spec unsubscribe(flag(), username() | plugin_id(),
                  subscriber_id(), [topic()]) -> ok | {error, overloaded
                                                       | not_ready}.
unsubscribe(false, User, SubscriberId, Topics) ->
    %% trade availability for consistency
    vmq_cluster:if_ready(fun unsubscribe_op/3, [User, SubscriberId, Topics]);
unsubscribe(true, User, SubscriberId, Topics) ->
    %% trade consistency for availability
    unsubscribe_op(User, SubscriberId, Topics).

unsubscribe_op(User, SubscriberId, Topics) ->
    rate_limited_op(
      fun() ->
              del_subscriptions(Topics, SubscriberId)
      end,
      fun(_) ->
              _ = [vmq_exo:decr_subscription_count() || _ <- Topics],
              _ = vmq_plugin:all(on_unsubscribe, [User, SubscriberId, Topics]),
              ok
      end).

delete_subscriptions(SubscriberId) ->
    del_subscriber(SubscriberId).

-spec register_subscriber(flag(), flag(), subscriber_id(), flag()) ->
    {ok, pid()} | {error, _}.
register_subscriber(false, _, SubscriberId, CleanSession) ->
    %% we don't allow multiple sessions using same subscriber id
    %% allow_multiple_sessions is needed for session balancing
    register_subscriber(SubscriberId, CleanSession);
register_subscriber(true, BalanceSessions, SubscriberId, _CleanSession) ->
    %% we allow multiple sessions using same subscriber id
    %%
    %% !!! CleanSession is disabled if multiple sessions are in use
    %%
    register_session(SubscriberId, BalanceSessions).

-spec register_subscriber(subscriber_id(), flag()) -> {ok, pid()} | {error, _}.
register_subscriber(SubscriberId, CleanSession) ->
    case vmq_reg_leader:register_subscriber(self(), SubscriberId,
                                            CleanSession) of
        {ok, QPid} when CleanSession->
            %% no need to remap
            {ok, QPid};
        {ok, QPid} ->
            remap_subscription(SubscriberId),
            {ok, QPid};
        R ->
            R
    end.

-spec register_session(subscriber_id(), flag()) -> {ok, pid()} | {error, _}.
register_session(SubscriberId, BalanceSessions) ->
    %% register_session allows to have multiple subscribers connected
    %% with the same session_id (as oposed to register_subscriber)
    SessionPid = self(),
    QPid = gen_server:call(?MODULE, {ensure_queue, SubscriberId}),
    ok = vmq_queue:add_session(QPid, SessionPid, false, true),
    vmq_queue:set_opts(QPid, [{deliver_mode, balance}|| true <- [BalanceSessions]]),
    {ok, QPid}.

migrate_session(SubscriberId, OtherQPid) ->
    case get_queue_pid(SubscriberId) of
        not_found ->
            ok;
        QPid ->
            vmq_queue:migrate(QPid, OtherQPid)
    end.

-spec register_subscriber_(pid(), subscriber_id(), flag()) ->
    {'ok', pid()} | {error, overloaded}.
register_subscriber_(SessionPid, SubscriberId, CleanSession) ->
    %% cleanup session for this client id if needed
    case CleanSession of
        true ->
            rate_limited_op(
              fun() ->
                      del_subscriber(SubscriberId)
              end,
              fun(ok) ->
                      register_subscriber__(SessionPid, SubscriberId, true);
                 ({error, overloaded}) ->
                      timer:sleep(100),
                      register_subscriber__(SessionPid, SubscriberId, true)
              end);
        false ->
            register_subscriber__(SessionPid, SubscriberId, false)
    end.

-spec register_subscriber__(pid(), subscriber_id(), flag()) -> {'ok', pid()} | {error, _}.
register_subscriber__(SessionPid, SubscriberId, CleanSession) ->
    %% TODO: make this more efficient, currently we have to rpc every
    %% node in the cluster
    QPid = gen_server:call(?MODULE, {ensure_queue, SubscriberId}),
    lists:foreach(
      fun(Node) ->
              case Node == node() of
                  true ->
                      ignore;
                  false ->
                      rpc:call(Node, ?MODULE, migrate_session, [SubscriberId, QPid])
              end
      end, vmq_cluster:nodes()),
    ok = vmq_queue:add_session(QPid, SessionPid, CleanSession, false),
    {ok, QPid}.

-spec publish(msg()) -> 'ok' | {'error', _}.
publish(#vmq_msg{trade_consistency=true,
                 reg_view=RegView,
                 mountpoint=MP,
                 routing_key=Topic,
                 payload=Payload,
                 retain=IsRetain} = Msg) ->
    %% trade consistency for availability
    %% if the cluster is not consistent at the moment, it is possible
    %% that subscribers connected to other nodes won't get this message
    case IsRetain of
        true when Payload == <<>> ->
            %% retain delete action
            vmq_retain_srv:delete(MP, Topic);
        true ->
            %% retain set action
            vmq_retain_srv:insert(MP, Topic, Payload),
            RegView:fold(MP, Topic, fun publish/2, Msg#vmq_msg{retain=false}),
            ok;
        false ->
            RegView:fold(MP, Topic, fun publish/2, Msg),
            ok
    end;
publish(#vmq_msg{trade_consistency=false,
                 reg_view=RegView,
                 mountpoint=MP,
                 routing_key=Topic,
                 payload=Payload,
                 retain=IsRetain} = Msg) ->
    %% don't trade consistency for availability
    case vmq_cluster:is_ready() of
        true when (IsRetain == true) and (Payload == <<>>) ->
            %% retain delete action
            vmq_retain_srv:delete(MP, Topic);
        true when (IsRetain == true) ->
            %% retain set action
            vmq_retain_srv:insert(MP, Topic, Payload),
            RegView:fold(MP, Topic, fun publish/2, Msg#vmq_msg{retain=false}),
            ok;
        true ->
            RegView:fold(MP, Topic, fun publish/2, Msg),
            ok;
        false ->
            {error, not_ready}
    end.

%% publish/2 is used as the fold function in RegView:fold/4
publish({SubscriberId, QoS}, Msg) ->
    publish(Msg, QoS, get_queue_pid(SubscriberId));
publish(Node, Msg) ->
    case vmq_cluster:publish(Node, Msg) of
        ok ->
            Msg;
        {error, Reason} ->
            lager:warning("can't publish to remote node ~p due to '~p'", [Node, Reason]),
            Msg
    end.

publish(Msg, _, not_found) -> Msg;
publish(Msg, QoS, QPid) ->
    ok = vmq_queue:enqueue(QPid, {deliver, QoS, Msg}),
    Msg.

-spec deliver_retained(subscriber_id(), pid(), topic(), qos()) -> 'ok'.
deliver_retained({MP, _}, QPid, Topic, QoS) ->
    vmq_retain_srv:match_fold(
      fun ({T, Payload}, _) ->
              Msg = #vmq_msg{routing_key=T,
                             payload=Payload,
                             retain=true,
                             qos=QoS,
                             dup=false},
              vmq_queue:enqueue(QPid, {deliver, QoS, Msg})
      end, ok, MP, Topic).

deliver_all_retained_for_subscriber_id(SubscriberId) ->
    case subscriptions_for_subscriber_id(SubscriberId) of
        [] ->
            ok;
        Subs ->
            case get_queue_pid(SubscriberId) of
                not_found ->
                    ok;
                QPid ->
                    lists:foreach(
                      fun({Topic, QoS, _}) ->
                              deliver_retained(SubscriberId, QPid, Topic, QoS)
                      end, Subs)
            end
    end.

subscriptions_for_subscriber_id(SubscriberId) ->
    plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId, [{default, []}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% RPC Callbacks / Maintenance
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec wait_til_ready() -> 'ok'.
wait_til_ready() ->
    case catch vmq_cluster:if_ready(fun() -> true end, []) of
        true ->
            ok;
        _ ->
            timer:sleep(100),
            wait_til_ready()
    end.

-spec direct_plugin_exports(module()) -> {function(), function(), {function(), function()}} | {error, invalid_config}.
direct_plugin_exports(Mod) when is_atom(Mod) ->
    %% This Function exports a generic Register, Publish, and Subscribe
    %% Fun, that a plugin can use if needed. Currently all functions
    %% block until the cluster is ready.
    case {vmq_config:get_env(trade_consistency, false),
          vmq_config:get_env(max_queued_messages, 1000),
          vmq_config:get_env(default_reg_view, vmq_reg_trie)} of
        {TradeConsistency, QueueSize, DefaultRegView}
              when is_boolean(TradeConsistency)
                   and (QueueSize >= 0)
                   and is_atom(DefaultRegView) ->
            MountPoint = "",
            ClientId = fun(T) ->
                               base64:encode_to_string(
                                 integer_to_binary(
                                   erlang:phash2(T)
                                  )
                                )
                       end,
            CallingPid = self(),
            SubscriberId = {MountPoint, ClientId(CallingPid)},
            User = {plugin, Mod, CallingPid},

            RegisterFun =
            fun() ->
                    PluginPid = self(),
                    wait_til_ready(),
                    PluginSessionPid = spawn_link(
                                         fun() ->
                                                 plugin_queue_loop(PluginPid, Mod)
                                         end),
                    _ = register_subscriber_(PluginSessionPid, SubscriberId, true)

            end,

            PublishFun =
            fun(Topic, Payload) ->
                    wait_til_ready(),
                    Msg = #vmq_msg{routing_key=vmq_topic:words(Topic),
                                   mountpoint=MountPoint,
                                   payload=Payload,
                                   dup=false,
                                   retain=false,
                                   trade_consistency=TradeConsistency,
                                   reg_view=DefaultRegView
                                  },
                    publish(Msg)
            end,

            SubscribeFun =
            fun(Topic) when is_list(Topic) ->
                    wait_til_ready(),
                    CallingPid = self(),
                    User = {plugin, Mod, CallingPid},
                    subscribe(TradeConsistency, User,
                              {MountPoint, ClientId(CallingPid)}, [{Topic, 0}]);
               (_) ->
                    {error, invalid_topic}
            end,

            UnsubscribeFun =
            fun(Topic) when is_list(Topic) ->
                    wait_til_ready(),
                    CallingPid = self(),
                    User = {plugin, Mod, CallingPid},
                    unsubscribe(TradeConsistency, User,
                                {MountPoint, ClientId(CallingPid)}, [Topic]);
               (_) ->
                    {error, invalid_topic}
            end,
            {RegisterFun, PublishFun, {SubscribeFun, UnsubscribeFun}};
        _ ->
            {error, invalid_config}
    end.


plugin_queue_loop(PluginPid, PluginMod) ->
    receive
        {mail, QPid, new_data} ->
            vmq_queue:active(QPid),
            plugin_queue_loop(PluginPid, PluginMod);
        {mail, QPid, Msgs, _, _} ->
            lists:foreach(fun({deliver, QoS, #vmq_msg{
                                                routing_key=RoutingKey,
                                                payload=Payload,
                                                retain=IsRetain,
                                                dup=IsDup}}) ->
                                  PluginPid ! {deliver, lists:flatten(vmq_topic:unword(RoutingKey)),
                                               Payload,
                                               QoS,
                                               IsRetain,
                                               IsDup};
                             (Msg) ->
                                  lager:warning("drop message ~p for plugin ~p", [Msg, PluginMod]),
                                  ok
                          end, Msgs),
            vmq_queue:notify(QPid),
            plugin_queue_loop(PluginPid, PluginMod);
        Other ->
            exit({unknown_msg_in_plugin_loop, Other})
    end.


subscribe_subscriber_changes() ->
    plumtree_metadata_manager:subscribe(?SUBSCRIBER_DB),
    fun
        ({deleted, ?SUBSCRIBER_DB, _, Val})
          when (Val == ?TOMBSTONE) or (Val == undefined) ->
            ignore;
        ({deleted, ?SUBSCRIBER_DB, SubscriberId, Subscriptions}) ->
            {delete, SubscriberId, Subscriptions};
        ({updated, ?SUBSCRIBER_DB, SubscriberId, OldVal, NewSubs})
          when (OldVal == ?TOMBSTONE) or (OldVal == undefined) ->
            {update, SubscriberId, [], NewSubs};
        ({updated, ?SUBSCRIBER_DB, SubscriberId, OldSubs, NewSubs}) ->
            {update, SubscriberId, OldSubs -- NewSubs, NewSubs -- OldSubs};
        (_) ->
            ignore
    end.

fold_subscribers(FoldFun, Acc) ->
    Node = node(),
    plumtree_metadata:fold(
      fun ({_, ?TOMBSTONE}, AccAcc) -> AccAcc;
          ({{MP, _} = SubscriberId, Subs}, AccAcc) ->
              lists:foldl(
                fun({Topic, QoS, N}, AccAccAcc) when Node == N ->
                        FoldFun({MP, Topic, {SubscriberId, QoS, undefined}},
                                        AccAccAcc);
                   ({Topic, _, N}, AccAccAcc) ->
                        FoldFun({MP, Topic, N}, AccAccAcc)
                end, AccAcc, Subs)
      end, Acc, ?SUBSCRIBER_DB,
      [{resolver, lww}]).

fold_sessions(FoldFun, Acc) ->
    ets:foldl(fun(#session{subscriber_id=SubscriberId,
                           queue_pid=QPid}, AccAcc) ->
                      lists:foldl(
                        fun(SessionPid, AccAccAcc) ->
                                FoldFun(SubscriberId, SessionPid, AccAccAcc)
                        end, AccAcc, vmq_queue:get_sessions(QPid))
              end, Acc, vmq_session).


-spec add_subscriber([{topic(), qos()}], subscriber_id()) -> ok.
add_subscriber(Topics, SubscriberId) ->
    NewSubs =
    case plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId) of
        undefined ->
            [{Topic, QoS, node()} || {Topic, QoS} <- Topics];
        Subs ->
            lists:foldl(fun({Topic, QoS}, NewSubsAcc) ->
                                NewSub = {Topic, QoS, node()},
                                case lists:member(NewSub, NewSubsAcc) of
                                    true -> NewSubsAcc;
                                    false ->
                                        [NewSub|NewSubsAcc]
                                end
                        end, Subs, Topics)
    end,
    plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, NewSubs).


-spec del_subscriber(subscriber_id()) -> ok.
del_subscriber(SubscriberId) ->
    plumtree_metadata:delete(?SUBSCRIBER_DB, SubscriberId).

-spec del_subscriptions([topic()], subscriber_id()) -> ok.
del_subscriptions(Topics, SubscriberId) ->
    Subs = plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId, [{default, []}]),
    NewSubs =
    lists:foldl(fun({Topic, _, Node} = Sub, NewSubsAcc) ->
                        case Node == node() of
                            true ->
                                case lists:member(Topic, Topics) of
                                    true ->
                                        NewSubsAcc;
                                    false ->
                                        [Sub|NewSubsAcc]
                                end;
                            false ->
                                [Sub|NewSubsAcc]
                        end
                end, [], Subs),
    plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, NewSubs).

-spec remap_subscription(subscriber_id()) -> ok | {error, overloaded}.
remap_subscription(SubscriberId) ->
    rate_limited_op(
      fun() ->
              plumtree_metadata:get(?SUBSCRIBER_DB, SubscriberId, [{default, []}])
      end,
      fun ({error, overloaded}) ->
              timer:sleep(100),
              remap_subscription(SubscriberId);
          (Subs) ->
              Node = node(),
              NewSubs =
              lists:foldl(fun({Topic, QoS, N}, Acc) when N /= Node ->
                                  [{Topic, QoS, Node}|Acc];
                             (Sub, Acc) ->
                                  [Sub|Acc]
                          end, [], Subs),
              plumtree_metadata:put(?SUBSCRIBER_DB, SubscriberId, lists:usort(NewSubs)),
              ok
      end
     ).

-spec get_session_pids(subscriber_id()) ->
    {'error','not_found'} | {'ok', pid(), [pid()]}.
get_session_pids(SubscriberId) ->
    case get_queue_pid(SubscriberId) of
        not_found ->
            {error, not_found};
        QPid ->
            Pids = vmq_queue:get_sessions(QPid),
            {ok, QPid, Pids}
    end.

-spec get_queue_pid(subscriber_id()) -> pid() | not_found.
get_queue_pid(SubscriberId) ->
    case ets:lookup(vmq_session, SubscriberId) of
        [#session{queue_pid=Pid}] when is_pid(Pid) ->
            %% optimization
            Pid;
        _ ->
            not_found
    end.


client_stats() ->
    TotalSessions = total_sessions(),
    TotalInactiveSessions = total_inactive_sessions(),
    [{total, TotalSessions},
     {active, TotalSessions - TotalInactiveSessions},
     {inactive, TotalInactiveSessions}].

-spec total_sessions() -> non_neg_integer().
total_sessions() ->
    ets:info(vmq_session, size).

-spec total_inactive_sessions() -> non_neg_integer().
total_inactive_sessions() ->
    Pattern = #session{monitor=undefined, _='_'},
    ets:select_count(vmq_session, [{Pattern, [], [true]}]).

total_subscriptions() ->
    [{total, plumtree_metadata_manager:size(?SUBSCRIBER_DB)}].

-spec retained() -> non_neg_integer().
retained() ->
    vmq_retain_srv:size().

stored(SubscriberId) ->
    case get_queue_pid(SubscriberId) of
        not_found -> 0;
        QPid ->
            {_, Queued} = vmq_queue:status(QPid),
            Queued
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER CALLBACKS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #state{}}.


-spec handle_call(_, _, []) -> {reply, ok, []}.
handle_call({ensure_queue, SubscriberId}, _From, State) ->
    Ret =
    case get_queue_pid(SubscriberId) of
        not_found ->
            {ok, QPid} = vmq_queue_sup:start_queue(SubscriberId),
            MRef = monitor(process, QPid),
            ets:insert(vmq_session, #session{subscriber_id=SubscriberId,
                                             queue_pid=QPid,
                                             monitor=MRef,
                                             last_seen=epoch()}),
            QPid;
        QPid ->
            QPid
    end,
    {reply, Ret, State}.

-spec handle_cast(_, []) -> {noreply, []}.
handle_cast(_Req, State) ->
    {noreply, State}.

-spec handle_info(_, []) -> {noreply, []}.
handle_info({'DOWN', MRef, process, QueuePid, _}, State) ->
    ets:match_delete(vmq_session, #session{queue_pid=QueuePid, monitor=MRef, _='_'}),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

-spec terminate(_, _) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(_, _, _) -> {ok, _}.
code_change(_OldVSN, State, _Extra) ->
    {ok, State}.

epoch() ->
    {Mega, Sec, _} = os:timestamp(),
    (Mega * 1000000 + Sec).


-spec rate_limited_op(fun(() -> any()),
                      fun((any()) -> any())) -> any() | {error, overloaded}.
rate_limited_op(OpFun, SuccessFun) ->
    case jobs:ask(plumtree_queue) of
        {ok, JobId} ->
            try
                SuccessFun(OpFun())
            after
                jobs:done(JobId)
            end;
        {error, rejected} ->
            {error, overloaded}
    end.
