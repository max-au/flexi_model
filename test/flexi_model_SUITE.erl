%%-------------------------------------------------------------------
%% @author Maxim Fedorov <maximfca@gmail.com>
%% @doc
%% Tests flexi_model, a very recursive test, as it tests test model.
%%
%% @end
-module(flexi_model_SUITE).
-author("maximfca@gmail.com").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% API exports

%% Test server callbacks
-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    basic/0, basic/1,
    extended/1,
    stateful/1,
    multiple/1
]).

init_per_testcase(_TestCase, Config) ->
    {ok, Pid} = flexi_model:start_link(),
    [{model, Pid} | Config].

end_per_testcase(_TestCase, Config) ->
    gen_server:stop(?config(model, Config)).

all() ->
    [basic, extended, stateful, multiple].

%%--------------------------------------------------------------------
%% TEST CASES

basic() ->
    [{doc, "Manually build a cluster"}].

basic(Config) when is_list(Config) ->
    ?assertEqual(ok, flexi_model:add_application(chat, [{chat, {0, 2, 2}}], pool)),
    ?assertEqual(ok, flexi_model:add_release(chat_rel, [chat])),
    ?assertEqual(ok, flexi_model:add_node('chat1@localhost', europe, chat_rel, #{})),
    ?assertEqual(ok, flexi_model:add_node('chat2@localhost', europe, chat_rel, #{})),
    ?assertEqual(ok, flexi_model:start_node('chat1@localhost')),
    ?assertEqual(degraded, flexi_model:instance_state(chat, 'chat1@localhost')),
    ?assertEqual(ok, flexi_model:start_node('chat2@localhost')),
    ?assertEqual(running, flexi_model:instance_state(chat, 'chat1@localhost')),
    ?assertEqual(running, flexi_model:instance_state(chat, 'chat2@localhost')),
    ?assertEqual(ok, flexi_model:stop_node('chat1@localhost')),
    ?assertEqual(degraded, flexi_model:instance_state(chat, 'chat2@localhost')).

extended(Config) when is_list(Config) ->
    Model = ?config(model, Config),
    ?assertEqual(ok, flexi_model:add_application(core, [], undefined)),
    ?assertEqual(ok, flexi_model:add_application(offline, [core], pool)),
    ?assertEqual(ok, flexi_model:add_application(mon, [core], undefined)),
    %
    ChatDeps = [mon, {offline, {1, 2, 3}}, {chat, {0, 2, 2}}],
    ?assertEqual(ok, flexi_model:add_application(chat, ChatDeps, pool)),
    ?assertEqual(ok, flexi_model:add_release(offline_rel, [offline])),
    ?assertEqual(ok, flexi_model:add_release(chat_rel, [chat])),
    ?assertEqual(ok, flexi_model:add_node('offline@localhost', asia, offline_rel, #{})),
    ?assertEqual(ok, flexi_model:add_node('chat@localhost', europe, chat_rel, #{})),
    ?assertEqual(ok, flexi_model:start_node('offline@localhost')),
    ?assertEqual(ok, flexi_model:start_node('chat@localhost')),
    %%
    ?assertEqual(degraded, flexi_model:instance_state(chat, 'chat@localhost')),
    %%
    ?assertEqual(ok, flexi_model:add_node('offline2@localhost', asia, offline_rel, #{})),
    ?assertEqual(ok, flexi_model:start_node('offline2@localhost')),
    %
    ?assertEqual(ok, flexi_model:add_node('chat2@localhost', europe, chat_rel, #{})),
    ?assertEqual(ok, flexi_model:start_node('chat2@localhost')),
    %% check that starting second offline + chat node satisfies chat dependencies fully
    ?assertEqual(running, flexi_model:instance_state(chat, 'chat@localhost')),
    %%
    ?assertEqual(ok, flexi_model:stop_node('offline@localhost')),
    ?assertEqual(degraded, flexi_model:instance_state(chat, 'chat@localhost')),
    %
    ct:print("~s", [topo:format(sys:get_state(Model))]),
    ?assertEqual(ok, flexi_model:start_node('offline@localhost')),
    ct:print("~s", [topo:format(sys:get_state(Model))]),
    ?assertEqual(running, flexi_model:instance_state(chat, 'chat@localhost')),
    %
    ?assertEqual(ok, flexi_model:stop_node('chat2@localhost')),
    ?assertEqual(ok, flexi_model:stop_node('chat@localhost')),
    ?assertEqual(ok, flexi_model:stop_node('offline2@localhost')),
    ?assertEqual(ok, flexi_model:remove_node('chat2@localhost')),
    ?assertEqual(ok, flexi_model:remove_node('chat@localhost')),
    ?assertEqual(ok, flexi_model:stop_node('offline@localhost')),
    ?assertEqual(ok, flexi_model:remove_node('offline@localhost')),
    ?assertEqual(ok, flexi_model:remove_node('offline2@localhost')),
    ?assertEqual(ok, flexi_model:remove_release(offline_rel)),
    ?assertEqual(ok, flexi_model:remove_release(chat_rel)),
    ?assertEqual(ok, flexi_model:remove_application(chat)),
    ?assertEqual(ok, flexi_model:remove_application(mon)),
    ?assertEqual(ok, flexi_model:remove_application(offline)),
    ?assertEqual(ok, flexi_model:remove_application(core)).

stateful(Config) when is_list(Config) ->
    ?assertEqual(ok, flexi_model:add_application(offline, [], 4)), % 4 partitions
    ?assertEqual(ok, flexi_model:add_application(chat, [{offline, {1, 1, 1}}], undefined)),
    ?assertEqual(ok, flexi_model:add_release(all, [chat, offline])),
    ?assertEqual(ok, flexi_model:add_node('all@localhost', europe, all, #{offline => [1, 3]})),
    ?assertEqual(ok, flexi_model:start_node('all@localhost')),
    %%
    %ct:print("~s", [topo:format(sys:get_state(Model))]),
    ?assertEqual(starting, flexi_model:instance_state(chat, 'all@localhost')),
    %%
    ?assertEqual(ok, flexi_model:add_node('all1@localhost', europe, all, #{offline => [2, 4]})),
    ?assertEqual(ok, flexi_model:start_node('all1@localhost')),
    ?assertEqual(running, flexi_model:instance_state(chat, 'all@localhost')).

multiple(Config) when is_list(Config) ->
    %% offline tier
    Offline = flexi_model:add_tier(offline, [], 8, 4),
    %% push notifications
    Push = flexi_model:add_tier(push, [{notes, {0, 1, 1}}], 10, 2),
    %% spam filter
    Spam = flexi_model:add_tier(spam, [{notes, {0, 1, 1}}], pool, 4),
    %% account service
    Account = flexi_model:add_tier(account, [], pool, 5),
    %% notes
    _Notes = flexi_model:add_tier(notes, [{account, {0, 1, 1}}], pool, 1),
    %% chat
    Chat = flexi_model:add_tier(chat, [{offline, {1, 1, 1}}, {push, {0, 1, 1}},
        {account, {0, 1, 1}},
        {spam, {0, 2, 2}}, {chat, {0, 8, 12}}], pool, 12),
    %%
    _ = [flexi_model:start_node(Node) || Node <- Chat ++ Offline ++ Push ++ Spam ++ Account],
    %%
    ct:print("~s", [topo:format(sys:get_state(?config(model, Config)))]),
    %%
    ?assertEqual(running, flexi_model:instance_state(chat, 'chat-2@localhost')),
    ok.
