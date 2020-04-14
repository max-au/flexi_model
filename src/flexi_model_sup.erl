%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%% Flexible topology top-level supervisor
%%% @end
-module(flexi_model_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_all,
                 intensity => 0,
                 period => 1},
    ChildSpecs = [
        #{
            id => model,
            start => {flexi_model, start_link, [filename:join(code:priv_dir(topo), "flexi_model.bin")]}
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
