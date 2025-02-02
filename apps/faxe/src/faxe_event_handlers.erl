%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2020
%%% @doc
%%%
%%% @end
%%% Created : 02. Sep 2020 14:24
%%%-------------------------------------------------------------------
-module(faxe_event_handlers).
-author("heyoka").

%% API
-export([install/0, get_enabled/2, mqtt_opts/1]).

install() ->
  install_handlers(debug),
  install_handlers(conn_status),
  install_handlers(metrics),
  install_handlers(flow_changed).

install_handlers(Key) ->
  Handlers = get_enabled(Key, handler),
  [add_handler(HandlerType, atom_to_binary(Key, utf8), Opts) || {HandlerType, Opts} <- Handlers].

%% from a config proplist get only those with an 'enable' flag set to 'true'
get_enabled(Key, SubKey) ->
  All = faxe_config:get(Key, []),
  case proplists:get_value(SubKey, All) of
    undefined -> [];
    List when is_list(List) ->
      lists:filter(fun({_Type, E}) -> proplists:get_value(enable, E) end, List)
  end
.

add_handler(mqtt, HandlerName, Opts) ->
  MqttOpts = mqtt_opts(Opts),
  add_event_handler(HandlerName, handler_name(HandlerName,<<"mqtt">>), event_handler_mqtt, MqttOpts);
add_handler(amqp, HandlerName, Opts) ->
  AmqpOpts = faxe_util:proplists_merge(filter_options(Opts), faxe_config:get(amqp, [])),
  add_event_handler(HandlerName, handler_name(HandlerName, <<"amqp">>), event_handler_amqp, AmqpOpts).

mqtt_opts(HandlerOpts) ->
  faxe_util:proplists_merge(filter_options(HandlerOpts), faxe_config:get(mqtt, [])).

add_event_handler(<<"conn_status">>, Name, Type, Args) ->
  dataflow:add_conn_status_handler(Name, Type, Args);
add_event_handler(<<"debug">>, Name, Type, Args) ->
  dataflow:add_trace_handler(Name, Type, Args);
add_event_handler(<<"metrics">>, Name, Type, Args) ->
  dataflow:add_metrics_handler(Name, Type, Args);
add_event_handler(<<"flow_changed">>, Name, Type, Args) ->
  dataflow:add_flowchanged_handler(Name, Type, Args).


handler_name(Name, Type) ->
  N = binary_to_atom(<<Name/binary, "_handler_", Type/binary>>, utf8),
  N.

filter_options(Proplist) -> faxe_config:filter_empty_options(Proplist).
