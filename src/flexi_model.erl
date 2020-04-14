%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%% Flexible network topology model.
%%% @end
-module(flexi_model).
-author("maximfca@gmail.com").

%% API
-export([
    add_application/3,
    modify_application/3,
    remove_application/1,

    add_release/2,
    remove_release/1,

    add_tier/4,

    add_node/4,
    remove_node/1,
    start_node/1,
    stop_node/1,

    start_instance/2,
    stop_instance/2,
    instance_state/2,

    save/0,
    print/0
]).

%% gen_server callbacks
-export([
    start_link/0,
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    format_status/2,
    terminate/2
]).

-include("topo.hrl").

-spec add_application(app_name(), [dependency()], undefined | distributed()) ->
    ok | {error, Reason :: term(), Stack :: [term()]}.
add_application(Name, Deps, Provides) ->
    gen_server:call(?MODULE, {add_application, Name, Deps, Provides}).

-spec modify_application(app_name(), [dependency()], undefined | distributed()) ->
    ok | {error, Reason :: term(), Stack :: [term()]}.
modify_application(Name, Deps, Provides) ->
    gen_server:call(?MODULE, {modify_application, Name, Deps, Provides}).

-spec remove_application(app_name()) ->
    ok | {error, Reason :: term(), Stack :: [term()]}.
remove_application(Name) ->
    gen_server:call(?MODULE, {remove_application, Name}).

-spec add_release(release_name(), [app_name()]) ->
    ok | {error, Reason :: term(), Stack :: [term()]}.
add_release(Release, Apps) ->
    gen_server:call(?MODULE, {add_release, Release, Apps}).

-spec remove_release(release_name()) ->
    ok | {error, Reason :: term(), Stack :: [term()]}.
remove_release(Release) ->
    gen_server:call(?MODULE, {remove_release, Release}).

add_node(Node, Domain, Release, Partitioning) ->
    gen_server:call(?MODULE, {add_node, Node, Domain, Release, Partitioning}).

remove_node(Node) ->
    gen_server:call(?MODULE, {remove_node, Node}).

start_node(Node) ->
    gen_server:call(?MODULE, {start_node, Node}, infinity).

stop_node(Node) ->
    gen_server:call(?MODULE, {stop_node, Node}, infinity).

start_instance(Node, App) ->
    gen_server:call(?MODULE, {start_instance, Node, App}, infinity).

stop_instance(Node, App) ->
    gen_server:call(?MODULE, {stop_instance, Node, App}, infinity).

instance_state(Node, App) ->
    gen_server:call(?MODULE, {instance_state, Node, App}, infinity).

save() ->
    gen_server:call(?MODULE, save).

print() ->
    io:format("~s", [topo:format(sys:get_state(?MODULE))]).

add_tier(AppName, AppDeps, pool, NodeCount) ->
    ok = flexi_model:add_application(AppName, AppDeps, pool),
    ok = flexi_model:add_release(AppName, [AppName]),
    [
        begin
            Node = list_to_atom(lists:concat([AppName, "-", Seq, "@localhost"])),
            flexi_model:add_node(Node, asia, AppName, #{}),
            Node
        end || Seq <- lists:seq(1, NodeCount)];
%% make a tier of N nodes running M partitions of App
add_tier(AppName, AppDeps, Partitions, NodeCount) ->
    ((Partitions rem NodeCount) =/= 0 orelse Partitions < NodeCount)
        andalso error({invalid_partitioning, Partitions, NodeCount}),
    ok = flexi_model:add_application(AppName, AppDeps, Partitions),
    ok = flexi_model:add_release(AppName, [AppName]),
    [
        begin
            Node = list_to_atom(lists:concat([AppName, "-", Seq, "@localhost"])),
            flexi_model:add_node(Node, europe, AppName, #{AppName => lists:seq(Seq, Partitions, NodeCount)}),
            Node
        end || Seq <- lists:seq(1, NodeCount)].

%%--------------------------------------------------------------------
%% gen_server implementation

%%--------------------------------------------------------------------
%% @doc
%% Starts the server and links it to calling process.
%% Creates empty cluster.
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link(Filename) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Filename, []).

%% Simplification for tests: keep cluster in process state
init([]) ->
    {ok, #cluster{}};
init(Filename) ->
    put(filename, Filename),
    process_flag(trap_exit, true), %% for terminate/2 to work
    case file:read_file(Filename) of
        {ok, Bin} ->
            case binary_to_term(Bin) of
                #cluster{} = Saved ->
                    {ok, Saved};
                _ ->
                    {ok, #cluster{}}
            end;
        _ ->
            {ok, #cluster{}}
    end.

handle_call({add_application, App, Deps, Provides}, _From, State) ->
    try
        {reply, ok, topo:add_application(#application{name = App, depends_on = Deps, distributed = Provides}, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({modify_application, App, Deps, Provides}, _From, State) ->
    try
        {reply, ok, topo:modify_application(#application{name = App, depends_on = Deps, distributed = Provides}, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({remove_application, App}, _From, State) ->
    try
        {reply, ok, topo:remove_application(App, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({add_release, Name, Apps}, _From, State) ->
    try
        {reply, ok, topo:add_release(Name, Apps, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({remove_release, Name}, _From, State) ->
    try
        {reply, ok, topo:remove_release(Name, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({add_node, Node, Domain, Release, Partitioning}, _From, State) ->
    try
        {reply, ok, topo:add_node(Node, Domain, Release, Partitioning, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({remove_node, Node}, _From, State) ->
    try
        {reply, ok, topo:remove_node(Node, State)}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call({start_node, Node}, _From, State) ->
    try
        {reply, ok, topo:start_node(Node, State)}
    catch
        error:Reason:Stack ->
            {reply, {error, Reason, Stack}, State}
    end;

handle_call({stop_node, Node}, _From, State) ->
    try
        {reply, ok, topo:stop_node(Node, State)}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call({start_instance, Node, App}, _From, State) ->
    try
        {reply, ok, topo:start_instance(Node, App, State)}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call({stop_instance, Node, App}, _From, State) ->
    try
        {reply, ok, topo:stop_instance(Node, App, State)}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call({instance_state, Node, App}, _From, State) ->
    try
        #instance{state = IS} = topo:find_instance(Node, App, State),
        {reply, IS, State}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;

handle_call(save, _From, State) ->
    {reply, save_impl(State), State};

handle_call(_Request, _From, _State) ->
    error(badarg).

handle_cast(_Request, _State) ->
    error(badarg).

handle_info(_Info, _State) ->
    error(badarg).

terminate(_Reason, State) ->
    save_impl(State).

format_status(normal, [_PDict, State]) ->
    Formatted = topo:format(State),
    [{data, [{"State", lists:flatten(Formatted)}]}].

%%--------------------------------------------------------------------
%% Internal implementation

save_impl(State) ->
    get(filename) =/= undefined andalso
        file:write_file(get(filename), term_to_binary(State)).
