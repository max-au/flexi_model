%% Distributed application dependency model.
%%
%% Main idea: application dependencies can be local and
%%  distributed, and for the latter, application needs to acquire
%%  some capacity (e.g. members of process groups).
%%
%% For distributed dependency, it is modeled as an application instance
%%  with it's own state & health, depending on capacity availability.

%% Distributed application publishing and discovery model.
%% Examples:
%%  * statless, not partitioned app:         pool (application name defines pg scope)
%%  * partitioned app, 32 partitions:        32
-type distributed() ::  pool | pos_integer().

%% Legacy partitioning modes:
%%    {Group :: spg:name(), Partitions :: pos_integer()} | % partitioned
%%  * partitioned island-based app:          {session, primary, 32, failover, 3}
%%    {Primary :: spg:name(), Partitions :: pos_integer(), Failover :: spg:name(), Replicas :: pos_integer()}. % island-based

%% Distributed application capacity specification.
%% Release configuration may override this setting
%%
%% Partitioned services capacity deduced from:
%%  * all - all partitions requirements must be satisfied
%%  * neg_integer() - ignore this many partitions below capacity
% -type partition_capacity() :: all | neg_integer().

%% Instance does not start until capacity is at Min, and turns
%%  unhealthy at any time capacity falls below Min.
%% Instance health is degraded until capacity is at Ok
%% Instance is over-provisioned when capacity is above Max.
-type capacity() ::  {Min :: non_neg_integer(), Ok :: non_neg_integer(), Max :: non_neg_integer()}.

%% Dependency: local application, or distributed application (default capacity).
-type dependency() :: app_name() | {app_name(), capacity()}.

%% Type application name for readability.
-type app_name() :: atom().

%% Application definition, with dependencies
%% When implementation of the model is merged into Erlang/OTP,
%%  it should be a part of application resource file, and
%%  application controller taking care of initialisation.
-record (application, {
    %% Application name (used to reference apps in cluster)
    name :: app_name(),
    %% application dependencies, both local & distributed
    depends_on = [] :: [dependency()],
    %% application distribution, undefined if application is not distributed
    distributed = undefined :: undefined | distributed()
}).

-type application() :: #application{}.

%% NB: unlike local dependencies that cannot be circular, distributed
%%  dependencies are allowed to contain cycles in their dependency
%%  graph. Example: front-end application providing routing is expected
%%  to be cycling with itself. This is "weak dependency" model, where
%%  dependent service may be "unhealthy", "degraded", or "ok".

%% Release: collection of applications, sorted topologically to
%%  form boot sequence. It is not allowed to have duplicate applications
%%  in a single release.
-type release_name() :: atom().
-type release() :: [app_name()].

%%--------------------------------------------------------------------
%% Cluster runtime model

%% Instance state. Instance provides capacity upon entering any
%%  operational (unhealthy, degraded, running) state, and revokes
%%  when 'stopped'.
-type instance_state() ::
    stopped |   % instance is not started, [start -> starting]
    starting |  % starting, waits for dependencies, [another_app_started -> started, stop -> stopped]
    unhealthy | % running unhealthy, provides minimal capacity (for bootstrapping self-dependent services)
    degraded |  % running, provides partial capacity
    running.    % provides  full capacity

%% Application instance: materialised application.
-record(instance, {
    %% Application state & health
    state = stopped :: instance_state(),
    %% For partitioned applications, partition number
    partition = undefined :: undefined | [pos_integer()]
}).

-type instance() :: #instance{}.

%% Domain: purely for TLS/TCP selection
-type domain() :: asia | australia | europe.

-type node_state() :: up | down.

%% Single node running several applications
-record(node, {
    state = down :: node_state(),
    domain :: domain(),
    release :: release_name(),
    %% connections (bi-directional) to other nodes in 'up' state
    connected = [] :: [node()],
    %% instances running in this node
    instances = #{} :: #{app_name() => instance()}
}).

%%--------------------------------------------------------------------
%% Global state
-record(cluster, {
    apps = #{} :: #{app_name() => application()},
    releases = #{} :: #{release_name() => release()},
    nodes = #{} :: #{node() => #node{}}
}).

-type cluster() :: #cluster{}.

