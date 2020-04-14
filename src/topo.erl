%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%% Model implementation (stateless).
%% @end
-module(topo).
-author("maximfca@gmail.com").

%% API exports
-export([
    add_application/2,
    modify_application/2,
    remove_application/2,

    add_release/3,
    remove_release/2,

    add_node/5,
    remove_node/2,
    start_node/2,
    stop_node/2,

    start_instance/3,
    stop_instance/3,
    find_instance/3,

    format/1,
    domains/0
]).


-include("topo.hrl").

%%--------------------------------------------------------------------
%% Stateful property-based test machine to be implemented within tests:
%% Application topology events (what software developer does):
%%  * add/remove application
%%  * - change application dependencies  (requires versioning support)
%%  * add/remove a release
%%  * - change applications of a release (requires versioning support)
%%  * add/remove node to cluster [could be automated]
%%
%% Cluster topology events (automation does it):
%%  * start a node with release on it
%%  * stop a node
%%  * - kill a node - immediately drop all network connections to the node
%%  * - drop/restore network connection between 2 nodes
%%
%% Properties:
%%  * cannot add duplicate application or application with missing dependencies
%%  * cannot delete application that is a dependency of another application or release
%%  * cannot add dependency that does not exist
%%  * cannot add circular dependency between local applications
%%  * release names are unique
%%  * cannot delete a release that is deployed
%%
%%  * instance state/health changes as expected

%% Returns dependencies applications names.
-spec dependencies([dependency()]) -> [app_name()].
dependencies(Deps) ->
    [Dep || Dep <- Deps, is_atom(Dep)] ++ [Dep || {Dep, _Capacity} <- Deps].

-spec verify_dependency(app_name(), dependency(), #{app_name() => application()}) -> true.
verify_dependency(_Name, Dep, Apps) when is_atom(Dep) ->
    (not is_map_key(Dep, Apps)) andalso error({app_missing, Dep});
%% global application with capacity
verify_dependency(_Name, {Dep, {Min, Degraded, Max}}, _Apps) when is_atom(Dep), is_integer(Min),
    is_integer(Degraded), is_integer(Max), Min =< Degraded, Degraded =< Max ->
    true;
%% broken forms
verify_dependency(_Name, {Dep, Capacity}, _Apps) ->
    error({app_capacity, Dep, Capacity}).

-spec verify_distribution(distributed()) -> true.
verify_distribution(undefined) ->
    false;
verify_distribution(pool) ->
    true;
verify_distribution(Partitions) when is_integer(Partitions), Partitions > 0 ->
    true;
verify_distribution(Dist) ->
    error({invalid_distribution, Dist}).

%% New application: throws for duplicate apps or missing dependencies.
-spec add_application(application(), cluster()) -> cluster().
add_application(#application{name = Name, depends_on = Deps, distributed = Dist} = App, #cluster{apps = Apps} = Cluster) ->
    is_map_key(Name, Apps) andalso error({app_exists, Name}),
    verify_distribution(Dist),
    %% verify dependencies
    _ = [verify_dependency(Name, Dep, Apps) || Dep <- Deps],
    Cluster#cluster{apps = Apps#{Name => App}}.

%% Changes existing application, triggering cluster state recalculation
-spec modify_application(application(), cluster()) -> cluster().
modify_application(#application{name = Name, distributed = Dist} = NewApp, #cluster{apps = Apps} = Cluster) ->
    is_map_key(Name, Apps) orelse error({app_missing, Name}),
    case maps:get(Name, Apps) of
        NewApp ->
            Cluster;
        #application{distributed = Dist} ->
            %% only dependencies changed
            NewCluster = Cluster#cluster{apps = Apps#{Name => NewApp}},
            Dependents = [App || {App, #application{depends_on = Deps}} <- maps:to_list(Cluster#cluster.apps),
                lists:member(Name, dependencies(Deps))],
            trigger_global_wave(lists:usort([Name | Dependents]), NewCluster);
        #application{} ->
            %% distribution changed: this cannot be supported, a new app must be added
            %%  and old one removed
            error(not_supported)
    end.

%% Remove application. Application cannot be deployed anywhere, cannot be a dependency of
%%  anything.
-spec remove_application(app_name(), cluster()) -> cluster().
remove_application(Name, #cluster{apps = Apps, releases = Releases} = Cluster) ->
    is_map_key(Name, Apps) orelse error({app_missing, Name}),
    _ = [lists:member(Name, dependencies(Deps)) andalso error({app_dependency, DepName}) ||
        #application{name = DepName, depends_on = Deps} <- maps:values(Apps), Name =/= DepName],
    %% verify application is not a part of any release
    _ = [error({app_dependency, release, RelName})
        || {RelName, Rel} <- maps:to_list(Releases), lists:member(Name, Rel)],
    Cluster#cluster{apps = maps:remove(Name, Apps)}.

%% New release: release name must be unique, apps must exist
-spec add_release(release_name(), release(), cluster()) -> cluster().
add_release(Name, Release, #cluster{apps = Apps, releases = Releases} = Cluster) when is_list(Release) ->
    is_map_key(Name, Releases) andalso error({release_exists, Name}),
    % verify all dependencies exist
    _ = [is_map_key(App, Apps) orelse error({app_dependency_missing, Name, App}) || App <- Release],
    RelApps = recursive_apps(Release, Apps, []),
    Cluster#cluster{releases = Releases#{Name => RelApps}}.

%% Remove release. It must not be deployed to any node.
-spec remove_release(release_name(), cluster()) -> cluster().
remove_release(Name, #cluster{releases = Releases, nodes = Nodes} = Cluster) ->
    is_map_key(Name, Releases) orelse error({release_missing, Name}),
    %% verify release is not deployed anywhere
    _ = [error({release_deployed, Name, Node}) ||
        {Node, #node{release = Rel}} <- maps:to_list(Nodes), Rel =:= Name],
    Cluster#cluster{releases = maps:remove(Name, Releases)}.

%%--------------------------------------------------------------------
%% Physical cluster operations
%%

%% Helper function: returns node, if it exists and in expected state.
-spec get_node(node(), #{node() => #node{}}, node_state()) -> #node{}.
get_node(Node, Nodes, ExpectedState) ->
    is_map_key(Node, Nodes) orelse error({node_missing, Node}),
    #node{state = State} = Before = maps:get(Node, Nodes),
    State =/= ExpectedState andalso error({node_state, Node, State}),
    Before.

%% Partitioning: mapping between application name and partition number
-type partitioning() :: #{app_name() => pos_integer()}.

-spec make_instance(application(), partitioning()) -> instance().
make_instance(#application{name = AppName, distributed = Dist}, Partitioning) when is_map_key(AppName, Partitioning), not is_integer(Dist) ->
    error({not_partitioned, AppName});
make_instance(#application{name = AppName, distributed = Dist}, Partitioning) when is_map_key(AppName, Partitioning), is_integer(Dist) ->
    %% verify Partitions are good
    Parts = maps:get(AppName, Partitioning),
    _ = [(is_integer(P) andalso P =< Dist) orelse error({invalid_partition, AppName, P}) || P <- Parts],
    #instance{partition = Parts};
make_instance(#application{name = AppName, distributed = Dist}, _Partitioning) when is_integer(Dist) ->
    error({partitioning_required, AppName});
make_instance(_, _Partitioning) ->
    #instance{}.

%% Adds node to cluster. Node must not exist. Valid release must be specified.
-spec add_node(node(), domain(), release_name(), partitioning(), cluster()) -> cluster().
add_node(Node, Domain, Release, Partitioning, #cluster{nodes = Nodes, releases = Releases, apps = Apps} = Cluster) ->
    is_map_key(Node, Nodes) andalso error({node_exists, Node}),
    is_map_key(Release, Releases) orelse error({node_missing, Release}),
    lists:member(Domain, domains()) orelse error({node_domain, Domain}),
    ReleaseApps = maps:get(Release, Releases),
    % verify partitioning
    _ = [error({app_missing, App}) || App <- maps:keys(Partitioning), not lists:member(App, ReleaseApps)],
    %% make partitioned instances
    Instances = maps:from_list([{App, make_instance(maps:get(App, Apps), Partitioning)} || App <- ReleaseApps]),
    Cluster#cluster{nodes = Nodes#{Node => #node{release = Release, domain = Domain, instances = Instances}}}.

%% Removes node. Node muse be down.
-spec remove_node(node(), cluster()) -> cluster().
remove_node(Node, #cluster{nodes = Nodes} = Cluster) ->
    _ = get_node(Node, Nodes, down),
    Cluster#cluster{nodes = maps:remove(Node, Nodes)}.

%% Returns all applications of the release, recursively
recursive_apps([], _Apps, Acc) ->
    lists:usort(Acc);
recursive_apps([App | Tail], Apps, Acc) ->
    #application{depends_on = Deps} = maps:get(App, Apps),
    LocalDeps = [Dep || Dep <- Deps, is_atom(Dep)],
    recursive_apps(LocalDeps ++ Tail, Apps, [App | Acc]).

%% Starts node, release and all applications of this release. Triggers chain
%%  reaction for distributed instances state, ultimately triggering change of
%%  cluster health.
-spec start_node(node(), cluster()) -> cluster().
start_node(Node, #cluster{nodes = Nodes} = Cluster) ->
    #node{instances = Instances} = OldNode = get_node(Node, Nodes, down),
    %% all instances are stopped, but node is up
    NewCluster = Cluster#cluster{nodes = Nodes#{Node => OldNode#node{state = up}}},
    % start all apps of the release
    lists:foldl(fun (AppName, Acc) -> start_instance(AppName, Node, Acc) end, NewCluster, maps:keys(Instances)).

%% Stops node
-spec stop_node(node(), cluster()) -> cluster().
stop_node(Node, #cluster{nodes = OldNodes} = Cluster) ->
    #node{instances = Instances} = get_node(Node, OldNodes, up),
    NewCluster = lists:foldl(
        fun (AppName, Acc) -> stop_instance(AppName, Node, Acc) end,
        Cluster, maps:keys(Instances)),
    NewNodes = NewCluster#cluster.nodes,
    After = maps:get(Node, NewNodes),
    NewCluster#cluster{nodes = NewNodes#{Node => After#node{state = down}}}.

%% Connects nodes. May satisfy distributed application dependencies,
%%  thus change it's state, and change state of dependent applications.
%connect_nodes(_Node1, _Node2, Cluster) ->
%    Cluster.

%% Disconnects nodes. May change distributed application dependencies,
%%  leading to cascading changes in dependent application states.
%disconnect_nodes(_Node1, _Node2, Cluster) ->
%    Cluster.

%%--------------------------------------------------------------------
%% Application instance operations

%% Starts application instance in node of a cluster.
%% Behaves similar to ensure_all_started of OTP application controller.
%% When instance has no unsatisfied dependencies, it immediately goes 'started'/'ok'.
%% Otherwise it is set into 'starting'/'unhealthy' state, which then changes
%%  when dependency gets satisfied.
-spec start_instance(app_name(), node(), cluster()) -> cluster().
start_instance(AppName, Node, #cluster{nodes = Nodes} = Cluster) ->
    _ = get_instance(AppName, Node, get_node(Node, Nodes, up), stopped), %% just a check
    %% if there are no unsatisfied dependencies, set 'started'/'ok' and trigger chain reaction
    try_start_instance(AppName, Node, Cluster).

%% Stops selected instance
-spec stop_instance(app_name(), node(), cluster()) -> cluster().
stop_instance(AppName, Node, #cluster{nodes = Nodes} = Cluster) ->
    #node{instances = Instances} = OldNode = get_node(Node, Nodes, up),
    Instance = maps:get(AppName, Instances),
    NewNode = OldNode#node{instances = Instances#{AppName => Instance#instance{state = stopped}}},
    NewCluster = Cluster#cluster{nodes = Nodes#{Node => NewNode}},
    trigger_updates_wave(AppName, Node, NewNode, NewCluster).

%% attempts to start the instance, checking that all dependencies are now satisfied
-spec try_start_instance(app_name(), node(), cluster()) -> cluster().
try_start_instance(AppName, Node, #cluster{apps = Apps, nodes = Nodes} = Cluster) ->
    #application{depends_on = Deps} = maps:get(AppName, Apps),
    #node{instances = Instances} = OldNode = maps:get(Node, Nodes),
    #instance{state = OldState} = Instance = maps:get(AppName, Instances),
    case operational(OldState) of
        true ->
            Cluster;
        false ->
            case satisfied(Deps, Instances, running, Cluster) of
                BlockStart when BlockStart =:= stopped; BlockStart =:= starting; BlockStart =:= unhealthy ->
                    NewNode = OldNode#node{instances = Instances#{AppName => Instance#instance{state = starting}}},
                    Cluster#cluster{nodes = Nodes#{Node => NewNode}};
                Operational ->
                    NewNode = OldNode#node{instances = Instances#{AppName => Instance#instance{state = Operational}}},
                    NewCluster = Cluster#cluster{nodes = Nodes#{Node => NewNode}},
                    trigger_updates_wave(AppName, Node, NewNode, NewCluster)
            end
    end.

%% Checks if dependencies are satisfied, and returns resulting health, or false.
-spec satisfied([dependency()], #{app_name() => instance()}, instance_state(), cluster()) -> instance_state().
satisfied(_, _Instances, stopped, _Cluster) ->
    stopped;
satisfied(_, _Instances, starting, _Cluster) ->
    starting;
satisfied([], _Instances, Desired, _Cluster) ->
    Desired;
satisfied([{Dep, {Min, Degraded, _Max}} | Deps], Instances, Desired, #cluster{nodes = Nodes} = Cluster) ->
    %% distributed dependency, verify capacity, make connections etc.
    %% don't assume app name is the same as scope name
    #application{distributed = Dist} = maps:get(Dep, Cluster#cluster.apps),
    case get_total_capacity(Dist, Dep, Nodes) of
        Unhealthy when Unhealthy < Min ->
            satisfied(Deps, Instances, merge_state(unhealthy, Desired), Cluster);
        Partial when Partial < Degraded ->
            satisfied(Deps, Instances, merge_state(degraded, Desired), Cluster);
        _Operational ->
            satisfied(Deps, Instances, merge_state(running, Desired), Cluster)
    end;
satisfied([Dep | Deps], Instances, Desired, Cluster) ->
    %% local dependency
    #instance{state = State} = maps:get(Dep, Instances),
    satisfied(Deps, Instances, merge_state(State, Desired), Cluster).

%% returns total capacity available for distributed application Dep
get_total_capacity(pool, Dep, Nodes) ->
    get_capacity(Dep, 0, Nodes);
get_total_capacity(Partitions, Dep, Nodes) ->
    Init = list_to_tuple(lists:duplicate(Partitions, 0)),
    Capacity = get_capacity(Dep, Init, Nodes),
    %% total capacity: minimum of all capacities
    lists:min(tuple_to_list(Capacity)).

get_capacity(Dep, Init, Nodes) ->
    lists:foldl(
        fun (#node{instances = Instances, state = up}, Acc) when is_map_key(Dep, Instances) ->
            #instance{state = State, partition = Partitions} = maps:get(Dep, Instances),
            case operational(State) of
                false ->
                    Acc;
                true when Partitions =:= undefined ->
                    Acc + 1;
                true ->
                    lists:foldl(
                        fun (P, InAcc) -> setelement(P, InAcc, element(P, InAcc) + 1) end,
                        Acc, Partitions)
            end;
            (#node{}, Acc) ->
            Acc
        end,
        Init, maps:values(Nodes)).

%% Triggers updates: changes starting state of applications in the cluster
trigger_updates_wave(AppName, NodeName, Node, Cluster) ->
    NewCluster = trigger_local_updates(AppName, NodeName, Node, Cluster),
    #application{distributed = Dist} = maps:get(AppName, Cluster#cluster.apps),
    case Dist of
        undefined ->
            NewCluster;
        _ ->
            %% get list of all apps that had dependency on us
            Dependents = [App || {App, #application{depends_on = Deps}} <- maps:to_list(Cluster#cluster.apps),
                lists:member(AppName, dependencies(Deps))],
            trigger_global_wave(Dependents, NewCluster)
    end.

%% Scan all nodes in the cluster to see if changing application state triggered any other changes
trigger_global_wave(Dependents, #cluster{apps = Apps} = Cluster) ->
    %% distributed app, go through all nodes to see if any app
    %%  depends on it in a global way
    maps:fold(
        %% for every node in a cluster
        fun (NodeName, #node{instances = Instances}, ClusterNode) ->
            maps:fold(
                fun (_InstName, #instance{state = stopped}, ClusterIn) ->
                    ClusterIn;
                    (InstName, #instance{state = OldState} = Inst, ClusterIn) ->
                        case lists:member(InstName, Dependents) of
                            true ->
                                %% get the new state for all deps
                                #application{depends_on = DepsIn} = maps:get(InstName, Apps),
                                OldNodes = ClusterIn#cluster.nodes,
                                #node{instances = InstancesIn} = OldNode = maps:get(NodeName, OldNodes),
                                NewState = satisfied(DepsIn, InstancesIn, running, ClusterIn),
                                %% update the state
                                case NewState =:= OldState of
                                    true ->
                                        ClusterIn;
                                    false when NewState =:= unhealthy, OldState =:= starting ->
                                        ClusterIn;
                                    false ->
                                        NewInstances = Instances#{InstName => Inst#instance{state = NewState}},
                                        NewNode = OldNode#node{instances = NewInstances},
                                        NewCluster = ClusterIn#cluster{nodes = OldNodes#{NodeName => NewNode}},
                                        case operational(OldState) =:= operational(NewState) of
                                            true ->
                                                trigger_updates_wave(InstName, NodeName, NewNode, NewCluster);
                                            false ->
                                                NewCluster
                                        end
                                end;
                            false ->
                                ClusterIn
                        end
                  end, ClusterNode, Instances)
        end, Cluster, Cluster#cluster.nodes).


%% check for operational state change (publish or revoke processes)
operational(stopped) -> false;
operational(starting) -> false;
operational(unhealthy) -> true;
operational(degraded) -> true;
operational(running) -> true.

%% processes updates local to a node
trigger_local_updates(_AppName, Node, #node{instances = Instances}, Cluster) ->
    %% find any 'starting' instance of the node that depends on AppName, and is now satisfied
    maps:fold(
        fun (AppNameIn, #instance{state = starting}, Cluster1) ->
                try_start_instance(AppNameIn, Node, Cluster1);
            (_AppNameIn, _Instance, Cluster1) ->
                Cluster1
        end, Cluster, Instances).

%% Picks lowest state out of two supplied.
-spec merge_state(instance_state(), instance_state()) -> instance_state().
%merge_state(_Hs, stopped) -> stopped; % current implementation does not allow this
merge_state(stopped, _Current) -> stopped;
%merge_state(_Hs, starting) -> starting; % current implementation does not allow this
merge_state(starting, _Current) -> starting;
merge_state(_Hs, unhealthy) -> unhealthy; % once unhealthy, always unhealthy
merge_state(unhealthy, _Current) -> unhealthy; % ...or become unhealthy
merge_state(_Hs, degraded) -> degraded; % degraded overrides all but unhealthy
merge_state(Hs, _Current) -> Hs. % whether already degraded, or become so, does not matter

%% Returns App in the expected state, throws otherwise
-spec get_instance(app_name(), node(), #node{}, instance_state()) -> instance().
get_instance(AppName, Node, #node{state = NodeState, instances = Run}, AppState) ->
    NodeState =:= up orelse error({node_state, Node, NodeState}),
    is_map_key(AppName, Run) orelse error({instance_missing, Node, AppName}),
    #instance{state = State} = Instance = maps:get(AppName, Run),
    State =/= AppState andalso error({instance_state, Node, AppName, State}),
    Instance.

%% finds instance of an app in the cluster
find_instance(AppName, Node, #cluster{nodes = Nodes}) ->
    #node{instances = Instances} = get_node(Node, Nodes, up),
    case maps:find(AppName, Instances) of
        {ok, Instance} ->
            Instance;
        error ->
            error({instance_missing, Node, AppName})
    end.

%%--------------------------------------------------------------------
%% Utility functions

-spec domains() -> [domain()].
domains() -> [asia, australia, europe].

format_deps(Deps) ->
    lists:join(", ", [
        case Dep of
            {App, {Min, Deg, Max}} ->
                lists:flatten(io_lib:format("~s (~b/~b/~b)", [App, Min, Deg, Max]));
            App when is_atom(App) ->
                atom_to_list(App)
        end || Dep <- Deps]).


format(RelName, RelApps) ->
    io_lib:format("    ~-14s ~-80w~n", [RelName, RelApps]).

format(AppName, #instance{state = State, partition = undefined}, #cluster{}) ->
    io_lib:format("    ~-30s: ~14s~n", [AppName, State]);
format(AppName, #instance{state = State, partition = Parts}, #cluster{}) ->
    io_lib:format("    ~-30s: ~14s      ~-100w~n", [AppName, State, Parts]);

format(Name, #node{state = State, domain = Domain, release = Rel, instances = Run}, #cluster{} = Cluster) ->
    [io_lib:format("~-24s ~-9s: ~14s      ~-28s~n", [Name, Rel, State, Domain]) |
        [format(AppName, App, Cluster) || {AppName, App} <- maps:to_list(Run)]].

format(#application{name = AppName, depends_on = Deps, distributed = undefined}) ->
    io_lib:format("    ~-14s ~-70s~n", [AppName, format_deps(Deps)]);
format(#application{name = AppName, depends_on = Deps, distributed = Dist}) ->
    io_lib:format("    ~-14s ~-70s ~120p~n", [AppName, format_deps(Deps), Dist]);

format(#cluster{apps = Apps, releases = Releases, nodes = Nodes} = Cluster) ->
    "Application        Depends On                                                             Distributed\n" ++
        [format(App) || App <- maps:values(Apps)] ++
    "\nRelease            Applications\n" ++
        [format(RelName, RelApps) || {RelName, RelApps} <- maps:to_list(Releases)] ++
    "\nNode                     Release             State      Region/Partitions\n" ++
        [format(Name, Node, Cluster) || {Name, Node} <- maps:to_list(Nodes)].
