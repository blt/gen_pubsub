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

%% API
-export([
         start/3, start/4,
         start_link/3, start_link/4,
         publish/2, %% sync_publish/3,
         subscribe/2, %% sync_subscribe/3,
         unsubscribe/2, %% sync_unsubscribe/3
         wake_hib/5
        ]).

%% System exports
-export([
         system_continue/3,
         system_terminate/4,
         system_code_change/4
        ]).

%% Internal export -- required by stdlib's gen.erl
-export([init_it/6]).

%% Types
-export_type([ref/0, debug_flag/0]).

%% ===================================================================
%%  Types
%% ===================================================================

-type ref()        :: pid() | atom() | {Name :: atom(), node()} |
                      {via, Mod :: module(), Name :: atom()} |
                      {global, term()} | {local, atom()}.
-type debug_flag() :: trace | log | {logfile, file:filename()} |
                      statistics | debug.

%% ===================================================================
%%  Callback API
%% ===================================================================

-callback init(Args :: term()) -> {ok, State :: term()} |
                                  {ok, State :: term(), Timeout :: timer:time()}.

%% handle_publish -- invoked on gen_pubsub:publish/2
%%
%% When return is {ok, State} message is passed on to subscribers. When
%% {reject, State} nothing is passed on to subscribers.
-callback handle_publish(Msg :: term(),
                         From :: ref(),
                         State :: term()) -> {ok | reject, State :: term()}.

%% handle_subscribe -- invoked on gen_pubsub:subscribe/
-callback handle_subscribe(From :: ref(),
                           State :: term()) -> {ok | reject, State :: term()}.

-callback handle_unsubscribe(Reason :: (death | request),
                             From :: ref(),
                             State :: term()) -> {ok, State :: term()}.

%% ===================================================================
%%  API
%% ===================================================================

start(Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Mod, Args, Options).

start(Name, Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Name, Mod, Args, Options).

-spec start_link(Mod :: module(),
                 Args :: term(),
                 Options :: [{timeout, timer:time()} |
                             {debug, debug_flag()}])
                -> {ok, pid()} |
                   {error, {already_started, pid()}} |
                   {error, Reason :: term()}.
start_link(Mod, Args, Options) ->
    gen:start(?MODULE, link, Mod, Args, Options).

-spec start_link(Name :: {local, atom()} | {global, term()} | {via, atom(), term()},
                 Mod :: module(),
                 Args :: term(),
                 Options :: [{timeout, timer:time()} |
                             {debug, debug_flag()}])
                -> {ok, pid()} |
                   {error, {already_started, pid()}} |
                   {error, Reason :: term()}.
start_link(Name, Mod, Args, Options) ->
    gen:start(?MODULE, link, Name, Mod, Args, Options).

%% Issues a public request to the pub-sub process. The issuing process will
%% receive a {pubsub, PubSub :: ref(), published} message when all subscribed
%% processes have been notified.
-spec publish(PubSubRef :: ref(), Msg :: any()) -> ok.
publish(PubSubRef, Msg) -> cast(PubSubRef, pub_msg(Msg)).

%% Publishes a message to the pub-sub process subscribers. The calling process
%% will block for up to Timeout milliseconds.
%% -spec sync_publish(PubSub :: ref(),
%%                    Msg :: any(),
%%                    Timeout :: timer:time()) -> ok | {error, timeout}.

%% Issues a subscribe request to the pub-sub process. The issuing process will
%% receive a {pubsub, PubSub :: ref(), subscribed} message when subscribed.
-spec subscribe(PubSubRef :: ref(), Client :: ref()) -> ok.
subscribe(PubSubRef, Client) -> cast(PubSubRef, sub_msg(Client)).

%% Subscribes to the pub-sub process. The calling process will block for up to
%% Timeout milliseconds.
%% -spec sync_subscribe(PubSub :: ref(),
%%                      Client :: ref(),
%%                      Timeout :: timer:time()) -> ok | {error, timeout}.

%% Issues an unsubscribe request to the pub-sub process. The issuing process
%% will receive a {pubsub, PubSub, unsubscribed} message when unsubscribed.
-spec unsubscribe(PubSubRef :: ref(), Client :: ref()) -> ok.
unsubscribe(PubSubRef, Client) -> cast(PubSubRef, unsub_msg(Client)).

%% Unsubscribes from the pub-sub process. The calling process will block for up
%% to Timeout milliseconds.
%% -spec sync_unsubscribe(PubSub :: ref(),
%%                        Client :: ref(),
%%                        Timeout :: timer:time()) -> ok | {error, timeout}.

%% ===================================================================
%%  System Message API
%% ===================================================================

system_continue(Parent, Debug, [Name, State, Mod, Time]) ->
    loop(Parent, Name, State, Mod, Time, Debug).

-spec system_terminate(_, _, _, _) -> no_return().
system_terminate(Reason, _Parent, Debug, [Name, State, Mod, _Time]) ->
    terminate(Reason, Name, [], Mod, State, Debug).

system_code_change([Name, State, Mod, Time], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Extra) of
	{ok, NewState} -> {ok, [Name, NewState, Mod, Time]};
	Else -> Else
    end.

%% ===================================================================
%%  Internal Functions
%% ===================================================================

%%% ------------------------------------------------------------------
%%%  Initialization callback for gen
%%% ------------------------------------------------------------------
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    Name = name(Name0),
    Debug = gen:debug_options(Options),
    case catch Mod:init(Args) of
	{ok, State} ->
	    proc_lib:init_ack(Starter, {ok, self()}),
	    loop(Parent, Name, State, Mod, infinity, Debug);
	{ok, State, Timeout} ->
	    proc_lib:init_ack(Starter, {ok, self()}),
	    loop(Parent, Name, State, Mod, Timeout, Debug);
	{stop, Reason} ->
	    %% For consistency, we must make sure that the
	    %% registered name (if any) is unregistered before
	    %% the parent process is notified about the failure.
	    %% (Otherwise, the parent process could get
	    %% an 'already_started' error if it immediately
	    %% tried starting the process again.)
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	ignore ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, ignore),
	    exit(normal);
	{'EXIT', Reason} ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	Else ->
	    Error = {bad_return_value, Else},
	    proc_lib:init_ack(Starter, {error, Error}),
	    exit(Error)
    end.

%%% ------------------------------------------------------------------
%%%  The MAIN loop.
%%% ------------------------------------------------------------------
loop(Parent, Name, State, Mod, hibernate, Debug) ->
    proc_lib:hibernate(?MODULE,wake_hib,[Parent, Name, State, Mod, Debug]);
loop(Parent, Name, State, Mod, Time, Debug) ->
    Msg = receive
	      Input -> Input
	  after
              Time -> timeout
	  end,
    decode_msg(Msg, Parent, Name, State, Mod, Time, Debug, false).

wake_hib(Parent, Name, State, Mod, Debug) ->
    Msg = receive
	      Input -> Input
	  end,
    decode_msg(Msg, Parent, Name, State, Mod, hibernate, Debug, true).

decode_msg(Msg, Parent, Name, State, Mod, Time, Debug, Hib) ->
    case Msg of
	{system, From, get_state} ->
	    sys:handle_system_msg(get_state, From, Parent, ?MODULE, Debug,
				  {State, [Name, State, Mod, Time]}, Hib);
	{system, From, {replace_state, StateFun}} ->
	    NState = try StateFun(State) catch _:_ -> State end,
	    sys:handle_system_msg(replace_state, From, Parent, ?MODULE, Debug,
				  {NState, [Name, NState, Mod, Time]}, Hib);
	{system, From, Req} ->
	    sys:handle_system_msg(Req, From, Parent, ?MODULE, Debug,
				  [Name, State, Mod, Time], Hib);
	{'EXIT', Parent, Reason} ->
	    terminate(Reason, Name, Msg, Mod, State, Debug);
	_Msg when Debug =:= [] ->
	    handle_msg(Msg, Parent, Name, State, Mod);
	_Msg ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3,
				      Name, {in, Msg}),
	    handle_msg(Msg, Parent, Name, State, Mod, Debug1)
    end.

%%% ------------------------------------------------------------------
%%%  Send functions
%%% ------------------------------------------------------------------
-spec cast(Dest :: ref(), Msg :: any()) -> ok.
cast({global, Name}, Msg) ->
    catch global:send(Name, pub_msg(Msg)),
    ok;
cast({via, Mod, Name}, Msg) ->
    catch Mod:send(Name, pub_msg(Msg)),
    ok;
cast({Name, Node}=Dest, Msg) when is_atom(Name), is_atom(Node) ->
    do_send(Dest, Msg);
cast(Dest, Msg) when is_atom(Dest) ->
    do_send(Dest, Msg);
cast(Dest, Msg) when is_pid(Dest) ->
    do_send(Dest, Msg).

-spec do_send(Dest :: pid() | atom() | {Name :: atom(), node()},
              Msg  :: any())
             -> ok.
do_send(Dest, Msg) ->
    case catch erlang:send(Dest, Msg, [noconnect]) of
	noconnect ->
	    spawn(erlang, send, [Dest,Msg]);
	Other ->
            Other
    end.

%%-----------------------------------------------------------------
%% Format debug messages.  Print them as the call-back module sees
%% them, not as the real erlang messages.  Use trace for that.
%%-----------------------------------------------------------------
print_event(Dev, {in, Msg}, Name) ->
    case Msg of
	{'$gen_call', {From, _Tag}, Call} ->
	    io:format(Dev, "*DBG* ~p got call ~p from ~w~n",
		      [Name, Call, From]);
	{'$gen_cast', Cast} ->
	    io:format(Dev, "*DBG* ~p got cast ~p~n",
		      [Name, Cast]);
	_ ->
	    io:format(Dev, "*DBG* ~p got ~p~n", [Name, Msg])
    end;
print_event(Dev, {out, Msg, To, State}, Name) ->
    io:format(Dev, "*DBG* ~p sent ~p to ~w, new state ~w~n",
	      [Name, Msg, To, State]);
print_event(Dev, {noreply, State}, Name) ->
    io:format(Dev, "*DBG* ~p new state ~w~n", [Name, State]);
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~p dbg  ~p~n", [Name, Event]).

%%% ---------------------------------------------------
%%% Message handling functions
%%% ---------------------------------------------------

dispatch({'$gen_cast', Msg}, Mod, State) ->
    Mod:handle_cast(Msg, State);
dispatch(Info, Mod, State) ->
    Mod:handle_info(Info, State).

handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Mod) ->
    case catch Mod:handle_call(Msg, From, State) of
	{reply, Reply, NState} ->
	    reply(From, Reply),
	    loop(Parent, Name, NState, Mod, infinity, []);
	{reply, Reply, NState, Time1} ->
	    reply(From, Reply),
	    loop(Parent, Name, NState, Mod, Time1, []);
	{noreply, NState} ->
	    loop(Parent, Name, NState, Mod, infinity, []);
	{noreply, NState, Time1} ->
	    loop(Parent, Name, NState, Mod, Time1, []);
	{stop, Reason, Reply, NState} ->
	    {'EXIT', R} =
		(catch terminate(Reason, Name, Msg, Mod, NState, [])),
	    reply(From, Reply),
	    exit(R);
	Other -> handle_common_reply(Other, Parent, Name, Msg, Mod, State)
    end;
handle_msg(Msg, Parent, Name, State, Mod) ->
    Reply = (catch dispatch(Msg, Mod, State)),
    handle_common_reply(Reply, Parent, Name, Msg, Mod, State).

handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Mod, Debug) ->
    case catch Mod:handle_call(Msg, From, State) of
	{reply, Reply, NState} ->
	    Debug1 = reply(Name, From, Reply, NState, Debug),
	    loop(Parent, Name, NState, Mod, infinity, Debug1);
	{reply, Reply, NState, Time1} ->
	    Debug1 = reply(Name, From, Reply, NState, Debug),
	    loop(Parent, Name, NState, Mod, Time1, Debug1);
	{noreply, NState} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, infinity, Debug1);
	{noreply, NState, Time1} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, Time1, Debug1);
	{stop, Reason, Reply, NState} ->
	    {'EXIT', R} =
		(catch terminate(Reason, Name, Msg, Mod, NState, Debug)),
	    _ = reply(Name, From, Reply, NState, Debug),
	    exit(R);
	Other ->
	    handle_common_reply(Other, Parent, Name, Msg, Mod, State, Debug)
    end;
handle_msg(Msg, Parent, Name, State, Mod, Debug) ->
    Reply = (catch dispatch(Msg, Mod, State)),
    handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Debug).

handle_common_reply(Reply, Parent, Name, Msg, Mod, State) ->
    case Reply of
	{noreply, NState} ->
	    loop(Parent, Name, NState, Mod, infinity, []);
	{noreply, NState, Time1} ->
	    loop(Parent, Name, NState, Mod, Time1, []);
	{stop, Reason, NState} ->
	    terminate(Reason, Name, Msg, Mod, NState, []);
	{'EXIT', What} ->
	    terminate(What, Name, Msg, Mod, State, []);
	_ ->
	    terminate({bad_return_value, Reply}, Name, Msg, Mod, State, [])
    end.

handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Debug) ->
    case Reply of
	{noreply, NState} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, infinity, Debug1);
	{noreply, NState, Time1} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, Time1, Debug1);
	{stop, Reason, NState} ->
	    terminate(Reason, Name, Msg, Mod, NState, Debug);
	{'EXIT', What} ->
	    terminate(What, Name, Msg, Mod, State, Debug);
	_ ->
	    terminate({bad_return_value, Reply}, Name, Msg, Mod, State, Debug)
    end.

reply(Name, {To, Tag}, Reply, State, Debug) ->
    reply({To, Tag}, Reply),
    sys:handle_debug(Debug, fun print_event/3, Name,
		     {out, Reply, To, State} ).


reply({To, Tag}, Reply) ->
    catch To ! {Tag, Reply}.

%%% ---------------------------------------------------
%%% Terminate the server.
%%% ---------------------------------------------------

-spec terminate(_, _, _, _, _, _) -> no_return().
terminate(Reason, Name, Msg, Mod, State, Debug) ->
    case catch Mod:terminate(Reason, State) of
	{'EXIT', R} ->
	    error_info(R, Name, Msg, State, Debug),
	    exit(R);
	_ ->
	    case Reason of
		normal ->
		    exit(normal);
		shutdown ->
		    exit(shutdown);
		{shutdown,_}=Shutdown ->
		    exit(Shutdown);
		_ ->
		    FmtState =
			case erlang:function_exported(Mod, format_status, 2) of
			    true ->
				Args = [get(), State],
				case catch Mod:format_status(terminate, Args) of
				    {'EXIT', _} -> State;
				    Else -> Else
				end;
			    _ ->
				State
			end,
		    error_info(Reason, Name, Msg, FmtState, Debug),
		    exit(Reason)
	    end
    end.

error_info(_Reason, application_controller, _Msg, _State, _Debug) ->
    %% OTP-5811 Don't send an error report if it's the system process
    %% application_controller which is terminating - let init take care
    %% of it instead
    ok;
error_info(Reason, Name, Msg, State, Debug) ->
    Reason1 =
	case Reason of
	    {undef,[{M,F,A,L}|MFAs]} ->
		case code:is_loaded(M) of
		    false ->
			{'module could not be loaded',[{M,F,A,L}|MFAs]};
		    _ ->
			case erlang:function_exported(M, F, length(A)) of
			    true ->
				Reason;
			    false ->
				{'function not exported',[{M,F,A,L}|MFAs]}
			end
		end;
	    _ ->
		Reason
	end,
    error_logger:format("** Generic server ~p terminating \n"
                        "** Last message in was ~p~n"
                        "** When Server state == ~p~n"
                        "** Reason for termination == ~n** ~p~n",
                        [Name, Msg, State, Reason1]),
    sys:print_log(Debug),
    ok.

%% -------------------------------------------------------------------
%%  Miscellanious
%% -------------------------------------------------------------------

pub_msg(Msg)      -> {'$gen_pubsub_publish', Msg}.
sub_msg(Client)   -> {'$gen_pubsub_subscribe', Client}.
unsub_msg(Client) -> {'$gen_pubsub_unsubscribe', Client}.

%% via gen_server.erl
name({local,Name}) -> Name;
name({global,Name}) -> Name;
name({via,_, Name}) -> Name;
name(Pid) when is_pid(Pid) -> Pid.

%% via gen_server.erl
unregister_name({local,Name}) ->
    _ = (catch unregister(Name));
unregister_name({global,Name}) ->
    _ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
    _ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
    Pid.

%% ===================================================================
%%  Tests
%% ===================================================================

-ifdef(TEST).

-endif.
