%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_shovel_dyn_worker_sup_sup).
-behaviour(mirrored_supervisor).

-export([start_link/0, init/1, adjust/2, stop_child/1, cleanup_specs/0]).

-import(rabbit_misc, [pget/2]).
-import(rabbit_data_coercion, [to_map/1, to_list/1]).

-include("rabbit_shovel.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-define(SUPERVISOR, ?MODULE).

start_link() ->
    Pid = case mirrored_supervisor:start_link(
                  {local, ?SUPERVISOR}, ?SUPERVISOR,
                  ?MODULE, []) of
            {ok, Pid0}                       -> Pid0;
            {error, {already_started, Pid0}} -> Pid0
          end,
    Shovels = rabbit_runtime_parameters:list_component(<<"shovel">>),
    [start_child({pget(vhost, Shovel), pget(name, Shovel)},
                 pget(value, Shovel)) || Shovel <- Shovels],
    {ok, Pid}.

adjust(Name, Def) ->
    case child_exists(Name) of
        true  -> stop_child(Name);
        false -> ok
    end,
    start_child(Name, Def).

start_child({VHost, ShovelName} = Name, Def) ->
    rabbit_log_shovel:debug("Asked to start a dynamic Shovel named '~ts' in virtual host '~ts'", [ShovelName, VHost]),
    LockId = rabbit_shovel_locks:lock(Name),
    cleanup_specs(),
    rabbit_log_shovel:debug("Starting a mirrored supervisor named '~ts' in virtual host '~ts'", [ShovelName, VHost]),
    Result = case mirrored_supervisor:start_child(
           ?SUPERVISOR,
           {id(Name), {rabbit_shovel_dyn_worker_sup, start_link, [Name, obfuscated_uris_parameters(Def)]},
            transient, ?WORKER_WAIT, worker, [rabbit_shovel_dyn_worker_sup]}) of
        {ok,                      _Pid}  -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    %% release the lock if we managed to acquire one
    rabbit_shovel_locks:unlock(LockId),
    Result.

obfuscated_uris_parameters(Def) when is_map(Def) ->
    to_map(rabbit_shovel_parameters:obfuscate_uris_in_definition(to_list(Def)));
obfuscated_uris_parameters(Def) when is_list(Def) ->
    rabbit_shovel_parameters:obfuscate_uris_in_definition(Def).

child_exists(Name) ->
    lists:any(fun ({{_, N}, _, _, _}) -> N =:= Name end,
              mirrored_supervisor:which_children(?SUPERVISOR)).

stop_child({VHost, ShovelName} = Name) ->
    rabbit_log_shovel:debug("Asked to stop a dynamic Shovel named '~ts' in virtual host '~ts'", [ShovelName, VHost]),
    LockId = rabbit_shovel_locks:lock(Name),
    case get({shovel_worker_autodelete, Name}) of
        true -> ok; %% [1]
        _ ->
            ok = mirrored_supervisor:terminate_child(?SUPERVISOR, id(Name)),
            ok = mirrored_supervisor:delete_child(?SUPERVISOR, id(Name)),
            rabbit_shovel_status:remove(Name)
    end,
    rabbit_shovel_locks:unlock(LockId),
    ok.

%% [1] An autodeleting worker removes its own parameter, and thus ends
%% up here via the parameter callback. It is a transient worker that
%% is just about to terminate normally - so we don't need to tell the
%% supervisor to stop us - and as usual if we call into our own
%% supervisor we risk deadlock.
%%
%% See rabbit_shovel_worker:terminate/2

cleanup_specs() ->
    SpecsSet = sets:from_list([element(2, element(1, S)) || S <- mirrored_supervisor:which_children(?SUPERVISOR)]),
    ParamsSet = sets:from_list([ {proplists:get_value(vhost, S), proplists:get_value(name, S)}
                                 || S <- rabbit_runtime_parameters:list_component(<<"shovel">>) ]),
    F = fun(Name, ok) ->
            _ = mirrored_supervisor:delete_child(?SUPERVISOR, id(Name)),
            ok
        end,
    ok = sets:fold(F, ok, sets:subtract(SpecsSet, ParamsSet)).

%%----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.

id({V, S} = Name) ->
    {[V, S], Name}.
