%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%% Flexible topology model application
%%% @end
-module(flexi_model_app).
-author("maximfca@gmail.com").

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    flexi_model_sup:start_link().

stop(_State) ->
    ok.
