%%% Date: 05.01.17 - 14:11
%%% Ⓒ 2017 heyoka
%%% @doc
%%% rules for python callback classes
%%% * Callback class must be in a module with the lowercased name of the class ie:
%%%   module: "double", class: "Double"
%%% * python callback class must be a subclass of the class Faxe from module faxe
%%% * 'abstract' methods to implement are:
%%%      options() -> return a list of tuples // static
%%%      init(self, args) -> gets the object and a list of dicts with args from options()
%%%      handle_point(self, point_data) -> point_data is a dict
%%%      handle_batch(self, batch_data) -> batch_data is a list of dicts (points)
%%% * the callbacks need not return anything except for the options method
%%% * to emit data the method self.emit(data) has to be used, where data is a dict or a list of dicts
%%% @todo make a regular option out of the 'as' field


-module(c_python).
-author("Alexander Minichmair").

-include("faxe.hrl").
%% API
-behavior(df_component).
%% API
-export([
   init/3, process/3,
   handle_info/2, options/0,
   call_options/2, get_python/0,
   shutdown/1, decode_from_python/1]).

-callback execute(tuple(), term()) -> tuple().

-record(state, {
   node_id :: binary(),
   callback_module :: atom(),
   callback_class :: atom(),
   python_instance :: pid()|undefined,
   cb_object :: term(),
   func_calls = [],
   as = <<"data">>
}).


%% python method calls
-define(PYTHON_INFO_CALL, info).
-define(PYTHON_INIT_CALL, init).
-define(PYTHON_BATCH_CALL, batch).
-define(PYTHON_POINT_CALL, point).



-spec options() -> list(
   {atom(), df_types:option_name()} |
   {atom(), df_types:option_name(), df_types:option_value()}
).
options() -> [{cb_module, atom}, {cb_class, atom}].

%% @doc get the options required for the python callback class
-spec call_options(atom(), atom()) -> list(tuple()).
call_options(Module, Class) ->
   process_flag(trap_exit, true),
   P = get_python(),
   ModClass = list_to_atom(atom_to_list(Module)++"."++atom_to_list(Class)),
   Res =
      try pythra:func(P, ModClass, ?PYTHON_INFO_CALL, [Class]) of
         B when is_list(B) -> B
      catch
         _:{python,'builtins.ModuleNotFoundError', Reason,_}:_Stack ->
            Err = lists:flatten(io_lib:format("python module not found: ~s",[Reason])),
            {error, Err}
      end,
   python:stop(P),
   Res.

init(NodeId, _Ins, #{cb_module := Callback, cb_class := CBClass} = Args) ->
%%   ArgsKeys = maps:keys(Args),
%%   lager:info("ArgsKeys: ~p",[ArgsKeys]),
%%   lager:notice("ARgs for ~p: ~p", [Callback, Args]),
   PInstance = get_python(),
   %% create an instance of the callback class
   ClassInstance = pythra:init(PInstance, Callback, CBClass,
      [maps:without([cb_module, cb_class], Args#{<<"erl">> => self()})]),
%%   lager:info("python instantiation of ~p gives us: ~p",[{Callback, CBClass}, ClassInstance]),
   State = #state{
      callback_module = Callback,
      callback_class =  CBClass,
      cb_object = ClassInstance,
      node_id = NodeId,
      python_instance = PInstance},
   {ok, all, State}.

process(_Inp, #data_batch{points = Points} = Batch, State = #state{callback_module = _Mod, python_instance = Python,
   cb_object = Obj}) ->

   NewPoints = [data_map(P) || P <- Points],
   Data = flowdata:to_mapstruct(Batch#data_batch{points = NewPoints}),
%%   lager:warning("data: ~p",[Data]),
   NewObj = pythra:method(Python, Obj, ?PYTHON_BATCH_CALL, [Data]),
%%   lager:info("~p emitting: ~p after: ~p",[Mod, NewObj, T]),
   {ok, State#state{cb_object = NewObj}}
;
process(_Inp, #data_point{} = Point, State = #state{python_instance = Python, cb_object = Obj}) ->

   Data = flowdata:to_mapstruct(data_map(Point)),
%%   lager:warning("Data TO PYTHON: ~p" ,[Data]),
%%   {_, _, Ob} =
%%   case catch pythra:method(Python, Obj, ?PYTHON_POINT_CALL, [Data]) of
%%      Bin when is_binary(Bin) -> {ok, State#state{cb_object = Bin}};
%%      {'EXIT',{{python,PythonErr,Desc,{'$erlport.opaque',python,Err}}}} ->
%%         lager:warning("Python ERROR: ~p:~p :: ~s",[PythonErr, Desc, Err]),
%%         {ok, State};
%%      {'$erlport.opaque',python,Err} ->  lager:warning("Python ERROR: ~p",[Err]),
%%         {ok, State};
%%      Err -> lager:warning("Python Error: ~p",[Err]),
%%         {ok, State}
%%   end.
%%   ,
      NewObj = pythra:method(Python, Obj, ?PYTHON_POINT_CALL, [Data]),
%%   lager:warning("new obj has size: ~p", [byte_size(Ob)]),
   {ok, State#state{cb_object = NewObj}}.

%% python sends us data
handle_info({emit_data, Data0}, State) when is_map(Data0) ->
   Point = flowdata:point_from_json_map(Data0),
   {emit, {1, maybe_rename(Point, State)}, State};
handle_info({emit_data, Data}, State) when is_list(Data) ->
   Points = [flowdata:point_from_json_map(D) || D <- Data],
   Batch = #data_batch{points = Points},
   {emit, {1, maybe_rename(Batch, State)}, State};
handle_info({emit_data, {"Map", Data}}, State) when is_list(Data) ->
%%   lager:notice("got point data from python: ~p", [Data]),
   {emit, {1, Data}, State};
handle_info({python_error, Error}, State) ->
   lager:error("error from python: ~p", [Error]),
   {ok, State};
handle_info(_Request, State) ->
   lager:notice("got from python: ~p", [_Request]),
   {ok, State}.

shutdown(#state{python_instance = Python}) ->
   pythra:stop(Python).

%%%%%%%%%%%%%%%%%%%% internal %%%%%%%%%%%%

maybe_rename(Item, #state{as = undefined}) ->
   Item;
maybe_rename(Point = #data_point{}, #state{as = Alias}) ->
   data_map(Point, Alias);
maybe_rename(Batch = #data_batch{points = Points}, #state{as = Alias}) ->
   NewPoints = [data_map(Point, Alias) || Point <- Points],
   Batch#data_batch{points = NewPoints}.

data_map(#data_point{} = Point) ->
   data_map(Point, <<"data">>).

data_map(#data_point{fields = Fields} = Point, Key) ->
   case maps:is_key(Key, Fields) of
      true -> Point;
      false -> Point#data_point{fields = #{Key => Fields}}
   end.

get_python() ->
   {ok, PythonParams} = application:get_env(faxe, python),
   Path = proplists:get_value(script_path, PythonParams, "./python"),
   FaxePath = filename:join(code:priv_dir(faxe), "python/"),
   {ok, Python} = pythra:start_link([FaxePath, Path]),
   Python.


decode_from_python(Map) ->
   Dec = fun(K, V, NewMap) ->
      NewKey =
      case K of
         _ when is_binary(K) -> K;
         _ when is_list(K) -> list_to_binary(K)
      end,
      NewValue =
      case V of
         _ when is_map(V) -> decode_from_python(V);
         _ when is_list(V) -> list_to_binary(V);
         _ -> V
      end,
      NewMap#{NewKey => NewValue}
         end,
   maps:fold(Dec, #{}, Map).