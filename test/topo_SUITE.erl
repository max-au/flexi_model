%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%% Test SUITE for application topology placement.
%%% @end
-module(topo_SUITE).
-author("maximfca@gmail.com").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% API exports

%% Test server callbacks
-export([
    all/0
]).

%% Test cases
-export([
    basic/0, basic/1,
    extended/1,
    stateful/1,
    modify/1
]).

all() ->
    [stateful, basic, extended, modify].

-include("topo.hrl").

%%--------------------------------------------------------------------
%% TEST CASES

basic() ->
    [{doc, "Manually build a cluster"}].

basic(Config) when is_list(Config) ->
    C1 = topo:add_application(#application{name = chat, distributed = pool, depends_on = [{chat, {0, 2, 3}}]}, #cluster{}),
    C2 = topo:add_node('chat@localhost', europe, chat_rel, #{}, topo:add_release(chat_rel, [chat], C1)),
    _D1 = topo:start_node('chat@localhost', C2),
    ok.

extended(Config) when is_list(Config) ->
    Cluster = #cluster{},
    Cluster1 = topo:add_application(#application{name = core}, Cluster),
    C1 = topo:add_application(#application{name = offline, distributed = pool, depends_on = [core]}, Cluster1),
    CX1 = topo:add_application(#application{name = push, distributed = pool, depends_on = [core]}, C1),
    D1 = topo:add_application(#application{name = mon, depends_on = [core]}, CX1),
    %% chat: depends on mon, and offline - with default capacity of {1, 2, 3}
    D2 = topo:add_application(#application{name = chat, distributed = pool, depends_on = [mon, {offline, {1, 2, 3}}, {push, {1, 1, 3}}]}, D1),
    C11 = topo:add_release(offline_rel, [offline], D2),
    D11 = topo:add_release(chat_rel, [chat], C11),
    C111 = topo:add_node('offline@localhost', asia, offline_rel, #{}, D11),
    D111 = topo:add_node('chat@localhost', europe, chat_rel, #{}, C111),
    C1111 = topo:start_node('offline@localhost', D111),
    D1111 = topo:start_node('chat@localhost', C1111),
    #instance{state = ChatHealth} = topo:find_instance(chat, 'chat@localhost', D1111),
    ?assertEqual(starting, ChatHealth),
    %%
    CX1111 = topo:start_node('pushd@localhost', topo:add_node('pushd@localhost', asia, push, #{}, topo:add_release(push, [push], D1111))),
    #instance{state = CH0} = topo:find_instance(chat, 'chat@localhost', CX1111),
    ?assertEqual(degraded, CH0),
    %% eyeball...
    D1112 = topo:start_node('offline2@localhost', topo:add_node('offline2@localhost', asia, offline_rel, #{}, CX1111)),
    % ct:print("~s", [format(D1112)]),
    %% check that starting second offline node satisfies chat dependencies fully
    ct:print("~s", [topo:format(D1112)]),
    #instance{state = CH2} = topo:find_instance(chat, 'chat@localhost', D1112),
    ?assertEqual(running, CH2),
    %%
    C1112 = topo:stop_node('offline@localhost', D1112), %% TODO: this node is a dependency...
    #instance{state = CH3} = topo:find_instance(chat, 'chat@localhost', C1112),
    ct:print("~s", [topo:format(C1112)]),
    ?assertEqual(degraded, CH3),
    X1112 = topo:stop_node('chat@localhost', topo:stop_node('pushd@localhost', C1112)),
    Y1112 = topo:stop_node('offline2@localhost', X1112),
    C112 = topo:remove_node('chat@localhost', Y1112),
    D112 = topo:remove_node('offline@localhost', topo:remove_node('pushd@localhost', C112)),
    X112 = topo:remove_node('offline2@localhost', D112),
    C12 = topo:remove_release(offline_rel, topo:remove_release(push, X112)),
    D12 = topo:remove_release(chat_rel, C12),
    Z2 = topo:remove_application(chat, D12),
    Z3 = topo:remove_application(push, Z2),
    Z4 = topo:remove_application(mon, Z3),
    C2 = topo:remove_application(offline, Z4),
    C4 = topo:remove_application(core, C2),
    ?assertEqual(Cluster, C4).

stateful(Config) when is_list(Config) ->
    C1 = topo:add_application(#application{name = offline, distributed = 4}, #cluster{}), % 4 partitions
    C2 = topo:add_application(#application{name = chat, depends_on = [{offline, {1, 1, 1}}]}, C1),
    C3 = topo:add_release(all, [chat, offline], C2),
    C4 = topo:add_node('all@localhost', europe, all, #{offline => [1, 3]}, C3),
    C5 = topo:start_node('all@localhost', C4),
    %%
    ct:print("~s", [topo:format(C5)]),
    #instance{state = S1} = topo:find_instance(chat, 'all@localhost', C5),
    ?assertEqual(starting, S1),
    %%
    C6 = topo:add_node('all1@localhost', europe, all, #{offline => [2, 4]}, C5),
    C7 = topo:start_node('all1@localhost', C6),
    %%
    #instance{state = S2} = topo:find_instance(chat, 'all@localhost', C7),
    ?assertEqual(running, S2).

modify(Config) when is_list(Config) ->
    C1 = topo:add_application(#application{name = offline, distributed = 4}, #cluster{}), % 4 partitions
    C2 = topo:add_application(#application{name = chat, depends_on = [{offline, {1, 1, 1}}]}, C1),
    C3 = topo:add_release(all, [chat, offline], C2),
    C4 = topo:add_node('all@localhost', europe, all, #{offline => [1, 3]}, C3),
    XC5 = topo:start_node('all@localhost', C4),
    %% ensure removing a dependency starts the app
    C5 = topo:modify_application(#application{name = chat, depends_on = []}, XC5),
    #instance{state = S1} = topo:find_instance(chat, 'all@localhost', C5),
    ?assertEqual(running, S1),
    %% ensure adding dependency makes app unhealthy (but not stopped)
    ZC5 = topo:modify_application(#application{name = chat, depends_on = [{offline, {1, 1, 1}}]}, C5),
    ct:print("~s", [topo:format(ZC5)]),
    #instance{state = S2} = topo:find_instance(chat, 'all@localhost', ZC5),
    ?assertEqual(unhealthy, S2),
    %% ensure it is running again
    C6 = topo:add_node('all1@localhost', europe, all, #{offline => [2, 4]}, ZC5),
    C7 = topo:start_node('all1@localhost', C6),
    %%
    #instance{state = S3} = topo:find_instance(chat, 'all@localhost', C7),
    ?assertEqual(running, S3).

