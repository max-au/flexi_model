# Flexible Service Topology Model

This project models Erlang applications, releases, nodes, application 
instances running and relations between them.

## Why?

Currently there is no tool to test a specific service topology. 
It is easy to create a topology that cannot start due to circular 
dependency, or cannot work correctly because of accumulated call
timeout problem.

A system can be modeled as a set of Erlang applications. 
This model can be used to verify topology correctness, find deadlocks,
and visualise dependencies between applications.

This tool was originally designed to be a stateful model for
propery-based test of 'flexi' - flexible network topology, but
it also has value on it's own.

## Terms
[Refer to OTP documentation](https://erlang.org/doc/design_principles/des_princ.html)
* *application*: an Erlang/OTP application
* *release*: release, as outlined in OTP design principles
* *node*: an instance of Erlang VM running, potentially connected to a cluster of
other nodes
* *application instance*: an instance of an Erlang/OTP application running in a
specific node
* *process group*: collection of processes under one name ([to be released as part
of OTP 23](https://erlang.org/doc/man/pg_app.html))

## Dependencies

Key definition is a dependency. In Erlang, there is only strong 
dependency model. For example, OTP *ssl* application will not
start unless *crypto* application is already running. These dependencies
are encoded in the [application resource file](https://erlang.org/doc/man/app.html), *applications* key.
There is also *runtime_dependencies* key that is not currently enforced
and server mostly as a hint for problem reporting.

With *strong dependency* model any dependent application cannot start
until all dependencies are satisfied, and exits when any dependency is
has exited. Essentially, an application can be in one of these states:

* stopped
* operational - serving requests

flexi_model introduces a concept of weak, or *distributed*, dependency,
when an instance of an application depends on a certain "capacity"
provided by another application. Dependent application does not start 
until minimum capacity is reached. For every distributed dependency,
an application maintains one of the following states:

* unhealthy - capacity dropped below minimum (backpressure exercised)
* degraded - capacity is above minimum, but below normal operation range, 
not ready for failover
* running - at operational capacity (or above)

Application reports its own state as lowest of dependencies states. In
addition to stopped/operational states, an application could be:

* starting - startup blocked due to unhealthy dependency


## Capacity

Capacity for a distributed dependency is defined in a form of a triplet *{Min, Degraded, Max}*. 
When there is a need to satisfy distributed dependency to start an application, it is 
blocked until *Min* is reached.
When capacity is over *Max*, application may disconnect nodes that provide extra 
unused capacity.
To provide distributed capacity, an application must publish services:

* pool - stateless service
* positive integer (e.g. 42) - partitioned service (capacity is calculated 
as lowest of all partitions)

There are other, currently unsupported, publishing modes:

* {Scope, Group} - application joins process group Group in scope Scope
* {Scope, Group, Partitions} - partitioned service
* {Scope, Group, Partitions, Failover, Replicas} - island-based topology

## Entities

Following entities are modeled:

* Erlang *application*: name, dependencies (strong & distributed), provided
distributed services
* *Release*: runnable collection of applications
* *Node*: name, state, network connections, release associated, applications deployed 
* Application *instance*: state, distributed dependencies state

## Usage

There are several modes to use the model.

1. ```rebar3 shell```. If shut down gracefully (via `q().`), last known cluster 
state is saved. User enters commands, e.g. 
```flexi_model:add_application(notes, [core, {account, {0, 1, 2}}], notes)``` - 
add `notes` application that strongly depends on `core`, and have a distributed 
dependency on `account`, degraded when account capacity falls below 1, 
and does not need capacity above 2
2. ```Common Test```. Test case can specify cluster topology, and expected 
instance/node cluster status, to verify this topology is acceptable.

## Examples

Session example, rebar3 shell

    % create application core, that has no dependencies, and no published services
    1> flexi_model:add_application(core, [], undefined).
    ok
    % create application offline depending on core, with 32 partitions
    2> flexi_model:add_application(offline, [core], 32).
    ok
    3> % Create chat application, that depends on core, and has a weak
    % dependency on offline application, requiring 1 capacity to start,
    % and 2 to be operational (4 max capacity)
    % This application also has weak dependency on itself, meaning that
    % unless there is 4 other chat apps running, it is in a degraded state.
    4> flexi_model:add_application(chat, [core, {offline, {1, 2, 4}}, {chat, {0, 4, 8}}], pool).
    ok
    % create releases for chat & offline
    4> flexi_model:add_release(chat_rel, [chat]).
    ok
    5> flexi_model:add_release(off_rel, [offline]).
    ok
    % create nodes - off1, which is in asia, runs off_rel, and provides
    % partitions 1-3-5-7...-31
    7> flexi_model:add_node(off1, asia, off_rel, #{offline => lists:seq(1, 32, 2)}).
    ok
    % start node
    8> flexi_model:start_node(off1).
    ok
    % view cluster state
    9> flexi_model:print().
    <...>
    % add and start chat nodes
    10> flexi_model:add_node(chat1, asia, chat_rel, #{}).
    ok
    11> flexi_model:add_node(chat2, asia, chat_rel, #{}).
    ok
    12> flexi_model:start_node(chat1).
    ok
    13> flexi_model:start_node(chat2).
    ok
    % print cluster state, ensure chat app does not start 
    % keeps in starting state, until another offline node is added
    % and started, with partition mappings of 2-4-...-32
    15> flexi_model:add_node(off2, asia, off_rel, #{offline => lists:seq(2, 32, 2)}).
    ok
    16> flexi_model:start_node(off2).
    ok
    % ensure chat app started, and runs degraded, because 4 chat nodes are needed
    % to become running (healthy)
    ...
    % save the model
    26> flexi_model:save().
    ok
