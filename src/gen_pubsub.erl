-module(gen_pubsub).
%% This module provides a pub-sub behaviour. If you find yourself periodically
%% creating a process that keeps a susbscriber pool and publishes messages to
%% them on demand, this behaviour is for you.
%%
%% Have the following asynchronous API:
%%
%%  * subscribe / unsubscribe
%%  * publish
%%
%% No filtering is offered. It is assumed that if a client needs this feature
%% they will implement it above the behaviour level.

-behaviour(gen_server).

%% API
-export([
         start/3, start/4,
         start_link/3, start_link/4,
         publish/2, sync_publish/3,
         subscribe/2, sync_subscribe/3,
         unsubscribe/2, sync_unsubscribe/3
        ]).

%% [PRIVATE] internal functions
-export([
         do_publish/2
        ]).

%% [PRIVATE] gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%% Types
-export_type([dst/0]).

%% ===================================================================
%%  Records
%% ===================================================================

-record(state, {
          module            :: module(),
          client_state      :: any(),
          linked_procs = [] :: [{pid(), reference()}]
         }).

%% ===================================================================
%%  Macros
%% ===================================================================

-define(PUB(From, Msg), {'$gen_pubsub_publish', From, Msg}).
-define(SUB(Client),    {'$gen_pubsub_subscribe', Client}).
-define(UNSUB(Client),  {'$gen_pubsub_unsubscribe', Client}).

%% ===================================================================
%%  Types
%% ===================================================================

-type dst() :: pid() |
               port() |
               (RegName :: atom()) |
               {RegName :: atom(), Node :: node()}.

%% ===================================================================
%%  Callback API
%% ===================================================================

-callback init(Args :: term()) -> {ok, State :: term()}.

%% handle_publish -- invoked on gen_pubsub:publish/2
%%
%% When return is {ok, State} message is passed on to subscribers. When
%% {reject, State} nothing is passed on to subscribers.
-callback handle_publish(Msg :: term(),
                         From :: dst(),
                         State :: term()) -> {ok | reject, State :: term()}.

%% ===================================================================
%%  API
%% ===================================================================

start(Module, Args, Options) ->
    gen_server:start(?MODULE, {Module, Args}, Options).

start(ServerName, Module, Args, Options) ->
    gen_server:start(ServerName, ?MODULE, {Module, Args}, Options).

start_link(Module, Args, Options) ->
    gen_server:start_link(?MODULE, {Module, Args}, Options).

start_link(ServerName, Module, Args, Options) ->
    gen_server:start_link(ServerName, ?MODULE, {Module, Args}, Options).

%% @doc Asynchronously issues a publish request to the gen_pubsub process.
%%
%% Implementation `handle_publish/3' will be invoked. If return is `{ok, State}'
%% the issuing process will receive a `{pubsub, PubSub::dst(), published}'
%% message when all subscribed processes have been notified; subscribed
%% processes will receive a `{pubsub, Msg}' message. If the return of
%% `handle_publish/3' is `{reject, State}' no subscribed processes will receive
%% a messae; the issuing process will receive a `{pubsub, PubSub::dst(),
%% rejected}' message.
-spec publish(PubSubRef :: dst(), Msg :: any()) -> ok.
publish(PubSubRef, Msg) -> gen_server:cast(PubSubRef, ?PUB(self(), Msg)).

%% @doc Synchronously issues a publish request to the gen_pubsub process.
%%
%% Acts like publish/2 save that return is delayed until the arrival of
%% published | rejected message. The calling process will block for up to
%% Timeout milliseconds after which an `{error, timeout}' will be returned.
-spec sync_publish(PubSubRef :: dst(),
                   Msg       :: any(),
                   Timeout   :: timer:time()) -> ok | {error, timeout}.
sync_publish(PubSubRef, Msg, Timeout) ->
    ok = gen_pubsub:publish(PubSubRef, Msg),
    receive
        {pubsub, PubSubRef, published} -> ok
    after
        Timeout -> {error, timeout}
    end.

%% @doc Asynchronously issues a subscribe request to the gen_pubsub process.
%%
%% The issuing process will receive a `{pubsub, PubSub::dst(), subscribed}'
%% message when subscribed. Subscription is unconditional: no implementation
%% functions are invoked. If the issuing process is already subscribed to the
%% pubsub instance, `{pubsub, PubSub::dst(), already_subscribed}' will be
%% received.
-spec subscribe(PubSubRef :: dst(), Client :: dst()) -> ok.
subscribe(PubSubRef, Client) -> gen_server:cast(PubSubRef, ?SUB(Client)).

%% @doc Synchronously issues a subscribe request to the gen_pubsub process.
%%
%% The issuing process will block for up to Timeout milliseconds after which
%% `{error, timeout}' will be returned. Otherwise, like subscribe/2.
-spec sync_subscribe(PubSubRef :: dst(),
                     Client    :: dst(),
                     Timeout   :: timer:time()) -> ok | {error, timeout}
                                                      | {error, already_subscribed}.
sync_subscribe(PubSubRef, Client, Timeout) ->
    ok = gen_pubsub:subscribe(PubSubRef, Client),
    receive
        {pubsub, PubSubRef, subscribed}         -> ok;
        {pubsub, PubSubRef, already_subscribed} -> {error, already_subscribed}
    after
        Timeout -> {error, timeout}
    end.

%% @doc Asynchronously issues an unsubscribe request to the gen_pubsub process.
%%
%% The issuing process will receive a {pubsub, PubSub::dst(), unsubscribed}
%% message when unsubscribed, {pubsub, PubSub::dst(), not_subscribed} if not
%% subscribed..
-spec unsubscribe(PubSubRef :: dst(), Client :: dst()) -> ok.
unsubscribe(PubSubRef, Client) -> gen_server:cast(PubSubRef, ?UNSUB(Client)).

%% @doc Synchronously issues an usubscribe request to the gen_pubsub process.
%%
%% The issuing process will block for up to Timeout milliseconds after which
%% `{error, timeout}' will be returned. Otherwise, like unsubscribe/2.
-spec sync_unsubscribe(PubSubRef :: dst(),
                       Client    :: dst(),
                       Timeout   :: timer:time()) -> ok | {error, timeout}
                                                        | {error, not_subscribed}.
sync_unsubscribe(PubSubRef, Client, Timeout) ->
    ok = gen_pubsub:unsubscribe(PubSubRef, Client),
    receive
        {pubsub, PubSubRef, unsubscribed}   -> ok;
        {pubsub, PubSubRef, not_subscribed} -> {error, not_subscribed}
    after
        Timeout -> {error, timeout}
    end.

%% ===================================================================
%%  gen_server callbacks
%% ===================================================================

%% @private
init({Mod, Args}) ->
    {ok, ClientState} = Mod:init(Args),
    process_flag(trap_exit, true),
    {ok, #state{client_state=ClientState, module=Mod}}.

%% @private
handle_call(_Request, _From, State) ->
    {noreply, State}.

%% @private
handle_cast(?PUB(From, Msg), #state{module=Mod, linked_procs=LP}=S) ->
    case Mod:handle_publish(Msg, From, S#state.client_state) of
        {ok, NewClientState} ->
            Clients = [C || {C, _} <- LP],
            _ = spawn_link(?MODULE, do_publish, [Clients, Msg]),
            _ = erlang:send(From, {pubsub, self(), published}),
            {noreply, S#state{client_state=NewClientState}};
        {reject, NewClientState} ->
            _ = erlang:send(From, {pubsub, self(), rejected}),
            {noreply, S#state{client_state=NewClientState}}
    end;
handle_cast(?SUB(Client), #state{linked_procs=LP}=S) ->
    case proplists:get_value(Client, LP) of
        undefined ->
            MonRef = erlang:monitor(process, Client),
            _ = erlang:send(Client, {pubsub, self(), subscribed}),
            {noreply, S#state{linked_procs=[{Client, MonRef} | LP]}};
        MonRef when is_reference(MonRef) ->
            _ = erlang:send(Client, {pubsub, self(), already_subscribed}),
            {noreply, S}
    end;
handle_cast(?UNSUB(Client), #state{linked_procs=LP}=S) ->
    case proplists:get_value(Client, LP) of
        undefined ->
            _ = erlang:send(Client, {pubsub, self(), not_subscribed}),
            {noreply, S};
        MonRef when is_reference(MonRef) ->
            _DidFlush = erlang:demonitor(MonRef, [flush]),
            LPs = proplists:delete(Client, S#state.linked_procs),
            _ = erlang:send(Client, {pubsub, self(), unsubscribed}),
            {noreply, S#state{linked_procs=LPs}}
    end.

%% @private
handle_info({'EXIT', _Pid, _Reason}, #state{}=S) ->
    {noreply, S};
handle_info({'DOWN', MonRef, process, Client, _Info},
            #state{linked_procs=LP}=S) ->
    case proplists:get_value(Client, LP) of
        undefined ->
            {noreply, S};
        MonRef ->
            true = erlang:demonitor(MonRef, [flush]),
            LPs = proplists:delete(Client, S#state.linked_procs),
            {noreply, S#state{linked_procs=LPs}}
    end.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%%  Internal functions
%% ===================================================================

%% @private
-spec do_publish(Clients :: [dst()], Msg :: any()) -> ok.
do_publish(Clients, Msg) ->
    ok = lists:foreach(fun(C) -> erlang:send(C, {pubsub, Msg}) end, Clients).
