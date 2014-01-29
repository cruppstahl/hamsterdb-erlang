-module(ham_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile(export_all).

-record(state, {open = [],      % list of open databases [{name, handle}]
                databases = []  % list of existing databases [name]
                }).

test() ->
  eqc:module(?MODULE).

dbname() ->
  choose(1, 20).

initial_state() ->
  #state{}.

% ham_env_create_db ---------------------------------

create_db_pre(State) ->
  length(State#state.databases) < 30.

create_db_command(_State) ->
  {call, ?MODULE, create_db, [{var, env}, dbname()]}.

create_db(EnvHandle, DbName) ->
  case ham:env_create_db(EnvHandle, DbName) of
    {ok, DbHandle} ->
      DbHandle;
    {error, What} ->
      {error, What}
  end.

create_db_post(State, [_EnvHandle, DbName], Result) ->
  case lists:member(DbName, State#state.databases) of
    true ->
      eq(Result, {error, database_already_exists});
    false ->
      true
  end.

create_db_next(State, Result, [_EnvHandle, DbName]) ->
  case lists:member(DbName, State#state.databases) of
    true ->
      State;
    false ->
      State#state{databases = State#state.databases ++ [DbName],
                  open = State#state.open ++ [{DbName, Result}]}
  end.

% ham_env_open_db ---------------------------------

open_db_pre(State) ->
  State#state.open /= [].

open_db_command(_State) ->
  {call, ?MODULE, open_db, [{var, env}, dbname()]}.

open_db(EnvHandle, DbName) ->
  case ham:env_open_db(EnvHandle, DbName) of
    {ok, DbHandle} ->
      DbHandle;
    {error, What} ->
      {error, What}
  end.

open_db_post(State, [_EnvHandle, DbName], Result) ->
  case Result of
    {error, database_already_open} ->
      eq(lists:keymember(DbName, 1, State#state.open), true);
    {error, database_not_found} ->
      eq(lists:member(DbName, State#state.databases), false);
    {error, _} ->
      false;
    _Else ->
      true
  end.

open_db_next(State, Result, [_EnvHandle, DbName]) ->
  case (lists:member(DbName, State#state.databases) == true
          andalso lists:keymember(DbName, 1, State#state.open) == false) of
    true ->
      State#state{open = State#state.open ++ [{DbName, Result}]};
    false ->
      State
  end.

% ham_env_erase_db ---------------------------------

erase_db_pre(State) ->
  State#state.databases /= [].

erase_db_pre(State, [_EnvHandle, DbName]) ->
  lists:keymember(DbName, 1, State#state.open) == false
    andalso lists:member(DbName, State#state.databases) == true.

erase_db_command(_State) ->
  {call, ?MODULE, erase_db, [{var, env}, dbname()]}.

erase_db(EnvHandle, DbName) ->
  ham:env_erase_db(EnvHandle, DbName).

erase_db_post(_State, [_EnvHandle, _DbName], Result) ->
  Result == ok.

erase_db_next(State, _Result, [_EnvHandle, DbName]) ->
  State#state{databases = lists:delete(DbName, State#state.databases)}.

% ham_env_rename_db ---------------------------------

rename_db_pre(State) ->
  State#state.databases /= [].

rename_db_pre(State, [_EnvHandle, OldName, NewName]) ->
  % names must not be identical
  OldName /= NewName
    % database must not be open
    andalso lists:keymember(OldName, 1, State#state.open) == false
    % database must exist
    andalso lists:keymember(OldName, 1, State#state.databases) == true
    % new name must not exist
    andalso lists:member(NewName, State#state.databases) == false.

rename_db_command(_State) ->
  {call, ?MODULE, rename_db, [{var, env}, dbname(), dbname()]}.

rename_db(EnvHandle, OldName, NewName) ->
  ham:env_rename_db(EnvHandle, OldName, NewName).

rename_db_post(_State, [_EnvHandle, _OldName, _NewName], Result) ->
  Result == ok.

rename_db_next(State, _Result, [_EnvHandle, OldName, NewName]) ->
  State#state{databases
              = lists:delete(OldName, State#state.databases ++ [NewName])}.

% ham_env_close_db ---------------------------------

dbhandle(OpenList) ->
  elements([H || {_N, H} <- OpenList]).

db_close_pre(State) ->
  State#state.open /= [].

db_close_command(State) ->
  {call, ?MODULE, db_close, [dbhandle(State#state.open)]}.

db_close(DbHandle) ->
  ham:db_close(DbHandle).

db_close_post(_State, [_DbHandle], Result) ->
  Result == ok.

db_close_next(State, _Result, [DbHandle]) ->
  State#state{open = lists:keydelete(DbHandle, 2, State#state.open)}.

%weight(_State, db_close) ->
%  0;
%weight(_State, _) ->
%  10.

prop_ham() ->
  ?FORALL(Cmds, commands(?MODULE),
    begin
      {ok, EnvHandle} = ham:env_create("ham_eqc.db"),
      {History, State, Result} = run_commands(?MODULE, Cmds,
                                            [{env, EnvHandle}]),
      eqc_statem:show_states(
        pretty_commands(?MODULE, Cmds, {History, State, Result},
          aggregate(command_names(Cmds),
            collect(length(Cmds),
              begin
                ham:env_close(EnvHandle),
                Result == ok
              end))))
    end).

