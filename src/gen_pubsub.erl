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
         publish/2,
         subscribe/2,
         unsubscribe/2
        ]).

%% [PRIVATE] internal functions
-export([
         do_publish/4
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
%% -export_type([ref/0, debug_flag/0]).

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

%%% I'm unsure about this. I sort of think that publishing--which is done in the
%%% background--should have some notification _back_ to the sender. I am divided
%%% as to whether this should be a callback function or what.
%% -define(PUBSEND(UID), {'$gen_pubsub_publish_fin', UID}).

%% ===================================================================
%%  Types
%% ===================================================================

%% -type erlang:dst()        :: pid() | atom() | {Name :: atom(), node()} |
%%                       {via, Mod :: module(), Name :: atom()} |
%%                       {global, term()} | {local, atom()}.
%% -type debug_flag() :: trace | log | {logfile, file:filename()} |
%%                       statistics | debug.

%% ===================================================================
%%  Callback API
%% ===================================================================

-callback init(Args :: term()) -> {ok, State :: term()}. %% |
                                  %% {ok, State :: term(), Timeout :: timer:time()}.

%% handle_publish -- invoked on gen_pubsub:publish/2
%%
%% When return is {ok, State} message is passed on to subscribers. When
%% {reject, State} nothing is passed on to subscribers.
-callback handle_publish(Msg :: term(),
                         From :: erlang:dst(),
                         State :: term()) -> {ok | reject, State :: term()}.

%% handle_subscribe -- invoked on gen_pubsub:subscribe/
-callback handle_subscribe(From :: erlang:dst(),
                           State :: term()) -> {ok | reject, State :: term()}.

-callback handle_unsubscribe(Reason :: (death | request),
                             From :: erlang:dst(),
                             State :: term()) -> {ok, State :: term()}.

%% ===================================================================
%%  API
%% ===================================================================

start(Module, Args, Options) ->
    gen_server:start(?MODULE, {Module, Args}, Options).

start(ServerName, Module, Args, Options) ->
    gen_server:start(ServerName, ?MODULE, {Module, Args}, Options).

%% -spec start_link(Mod :: module(),
%%                  Args :: term(),
%%                  Options :: [{timeout, timer:time()} |
%%                              {debug, debug_flag()}])
%%                 -> {ok, pid()} |
%%                    {error, {already_started, pid()}} |
%%                    {error, Reason :: term()}.
start_link(Module, Args, Options) ->
    gen_server:start_link(?MODULE, {Module, Args}, Options).

%% -spec start_link(Name :: {local, atom()} | {global, term()} | {via, atom(), term()},
%%                  Mod :: module(),
%%                  Args :: term(),
%%                  Options :: [{timeout, timer:time()} |
%%                              {debug, debug_flag()}])
%%                 -> {ok, pid()} |
%%                    {error, {already_started, pid()}} |
%%                    {error, Reason :: term()}.
start_link(ServerName, Module, Args, Options) ->
    gen_server:start_link(ServerName, ?MODULE, {Module, Args}, Options).

%% Issues a public request to the pub-sub process. The issuing process will
%% receive a {pubsub, PubSub :: erlang:dst(), published} message when all subscribed
%% processes have been notified.
-spec publish(PubSubRef :: erlang:dst(), Msg :: any()) -> ok.
publish(PubSubRef, Msg) -> gen_server:cast(PubSubRef, ?PUB(self(), Msg)).

%% Publishes a message to the pub-sub process subscribers. The calling process
%% will block for up to Timeout milliseconds.
%% -spec sync_publish(PubSub :: erlang:dst(),
%%                    Msg :: any(),
%%                    Timeout :: timer:time()) -> ok | {error, timeout}.

%% Issues a subscribe request to the pub-sub process. The issuing process will
%% receive a {pubsub, PubSub :: erlang:dst(), subscribed} message when subscribed.
-spec subscribe(PubSubRef :: erlang:dst(), Client :: erlang:dst()) -> ok.
subscribe(PubSubRef, Client) -> gen_server:cast(PubSubRef, ?SUB(Client)).

%% Subscribes to the pub-sub process. The calling process will block for up to
%% Timeout milliseconds.
%% -spec sync_subscribe(PubSub :: erlang:dst(),
%%                      Client :: erlang:dst(),
%%                      Timeout :: timer:time()) -> ok | {error, timeout}.

%% Issues an unsubscribe request to the pub-sub process. The issuing process
%% will receive a {pubsub, PubSub, unsubscribed} message when unsubscribed.
-spec unsubscribe(PubSubRef :: erlang:dst(), Client :: erlang:dst()) -> ok.
unsubscribe(PubSubRef, Client) -> gen_server:cast(PubSubRef, ?UNSUB(Client)).

%% Unsubscribes from the pub-sub process. The calling process will block for up
%% to Timeout milliseconds.
%% -spec sync_unsubscribe(PubSub :: erlang:dst(),
%%                        Client :: erlang:dst(),
%%                        Timeout :: timer:time()) -> ok | {error, timeout}.

%% ===================================================================
%%  gen_server callbacks
%% ===================================================================

init({Mod, Args}) ->
    {ok, ClientState} = Mod:init(Args),
    process_flag(trap_exit, true),
    {ok, #state{client_state=ClientState, module=Mod}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(?PUB(From, Msg), #state{module=Mod, linked_procs=LP}=S) ->
    case Mod:handle_publish(Msg, From, S#state.client_state) of
        {ok, UID, NewClientState} ->
            Clients = [C || {C, _} <- LP],
            spawn_link(?MODULE, do_publish,
                       [self(), UID, Clients, Msg]),
            _ = erlang:send(From, {pubsub, self(), {published, UID}}),
            {noreply, S#state{client_state=NewClientState}};
        {reject, NewClientState} ->
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

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%%  Internal functions
%% ===================================================================

do_publish(_Parent, _UID, Clients, Msg) ->
    ok = lists:foreach(fun(C) -> erlang:send(C, {pubsub, Msg}) end, Clients).
