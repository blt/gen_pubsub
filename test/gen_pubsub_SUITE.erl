-module(gen_pubsub_SUITE).

-export([
         all/0, groups/0,
         init_per_testcase/2, end_per_testcase/2
        ]).

-export([
         start_test/1,
         subsciption_test/1,
         publish_test/1,
         crash_test/1
        ]).

%% The gen_pubsub behaviour
-export([
         init/1, handle_publish/3, handle_subscribe/2, handle_unsubscribe/3
        ]).

-define(RECVFAIL(ExpectedMsg, FailMsg), receive ExpectedMsg -> ok
                                        after 1000 -> test_server:fail(FailMsg) end).

-include_lib("common_test/include/ct.hrl").

all() -> [
          {group, basics}
         ].

init_per_testcase(start_test, Config) ->
    Config;
init_per_testcase(_Test, Config) ->
    {ok, PB} = gen_pubsub:start_link(?MODULE, [], []),
    [{pubsub, PB} | Config].

end_per_testcase(start_test, _Config) ->
    ok;
end_per_testcase(_Test, Config) ->
    PB = ?config(pubsub, Config),
    true = exit(PB, normal).

groups() ->
    [
     {basics, [], [start_test,
                   subsciption_test,
                   publish_test,
                   crash_test
                  ]}
    ].

%% ===================================================================
%%  Tests
%% ===================================================================

start_test(_Config) ->
    {ok, Pid0} = gen_pubsub:start(?MODULE, [], []),
    true = exit(Pid0, kill),

    {ok, Pid1} = gen_pubsub:start({local, pub_test_name_1},
                                  ?MODULE, [], []),
    true = exit(Pid1, kill),

    {ok, Pid2} = gen_pubsub:start_link(?MODULE, [], []),
    true = exit(Pid2, normal),

    {ok, Pid3} = gen_pubsub:start_link({local, pub_test_name_2},
                                       ?MODULE, [], []),
    true = exit(Pid3, normal),

    ok.

subsciption_test(_Config) ->
    {ok, PB} = gen_pubsub:start_link(?MODULE, [], []),

    ok = gen_pubsub:subscribe(PB, self()),
    ?RECVFAIL({pubsub, PB, subscribed}, subscription),

    ok = gen_pubsub:subscribe(PB, self()),
    ?RECVFAIL({pubsub, PB, already_subscribed}, repeat_subscription),

    ok = gen_pubsub:unsubscribe(PB, self()),
    ?RECVFAIL({pubsub, PB, unsubscribed}, unsubscription),

    ok = gen_pubsub:unsubscribe(PB, self()),
    ?RECVFAIL({pubsub, PB, not_subscribed}, repeat_unsubscription),

    true = exit(PB, normal).

publish_test(Config) ->
    PB = ?config(pubsub, Config),

    ok = gen_pubsub:subscribe(PB, self()),
    ?RECVFAIL({pubsub, PB, subscribed}, subscription),

    ok = gen_pubsub:publish(PB, message),
    ?RECVFAIL({pubsub, message}, publish_receipt),
    ?RECVFAIL({pubsub, PB, {published, test_uid}}, publish_receipt),

    ok = gen_pubsub:publish(PB, ignore_me_message),
    receive Msg -> test_server:fail({bad_receive, Msg})
    after 1000  -> ok
    end.

crash_test(Config) ->
    PB = ?config(pubsub, Config),

    Crasher = fun() ->
                      ok = gen_pubsub:subscribe(PB, self()),
                      ?RECVFAIL({pubsub, PB, subscribed}, subscription),
                      exit(fin)
              end,

    TrapFlag = process_flag(trap_exit, true),
    Pid = spawn_link(Crasher),
    ?RECVFAIL({'EXIT', Pid, fin}, crash_expected),
    process_flag(trap_exit, TrapFlag),

    ok = gen_pubsub:publish(PB, message),
    ?RECVFAIL({pubsub, PB, {published, test_uid}}, publish_receipt).

%% ===================================================================
%%  gen_pubsub callbacks
%% ===================================================================

init(_Args) ->
    {ok, state}.

handle_subscribe(_From, State) ->
    {ok, State}.

handle_unsubscribe(_Reason, _From, State) ->
    {ok, State}.

handle_publish(ignore_me_message, _From, State) ->
    {reject, State};
handle_publish(_Msg, _From, State) ->
    {ok, test_uid, State}.
