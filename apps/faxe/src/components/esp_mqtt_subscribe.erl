%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2019, <COMPANY>
%%% @doc
%%% Receive data from an mqtt-broker.
%%% @end
%%% Created : 27. May 2019 09:00
%%%-------------------------------------------------------------------
-module(esp_mqtt_subscribe).
-author("heyoka").

%% API
-behavior(df_component).

-include("faxe.hrl").
%% API
-export([init/3, process/3, options/0, handle_info/2, shutdown/1, check_options/0, metrics/0]).

-define(DEFAULT_PORT, 1883).
-define(DEFAULT_SSL_PORT, 8883).

%% state for direct publish mode
-record(state, {
   client,
   connected = false,
   reconnector,
   host,
   port,
   user,
   pass,
   qos,
   topic,
   topics,
   client_id,
   dt_field,
   dt_format,
   ssl = false,
   ssl_opts = [],
   topics_seen = [],
   fn_id,
   include_topic = true,
   topic_key,
   as,
   debug_mode = false
}).

options() -> [
   {host, binary, {mqtt, host}},
   {port, integer, {mqtt, port}},
   {user, string, {mqtt, user}},
   {pass, string, {mqtt, pass}},
   {client_id, string, undefined},
   {qos, integer, 1},
   {topic, binary, undefined},
   {topics, binary_list, undefined},
   {dt_field, string, <<"ts">>},
   {dt_format, string, ?TF_TS_MILLI},
   {include_topic, bool, true},
   {topic_as, string, <<"topic">>},
   {as, string, undefined},
   {ssl, is_set}].

check_options() ->
   [
      {one_of_params, [topic, topics]}
   ].

metrics() ->
   [
%%      {?METRIC_SENDING_TIME, histogram, [slide, 60], "Network time for sending a message."},
      {?METRIC_BYTES_READ, meter, [], "Size of item sent in kib."}
   ].

init({GId, NId}=NodeId, _Ins,
   #{ host := Host0, port := Port, topic := Topic, topics := Topics, dt_field := DTField, as := As,
      dt_format := DTFormat, user := User, pass := Pass, include_topic := IncludeTopic, topic_as := TopicKey,
      ssl := UseSSL, qos := Qos, client_id := CId} = _Opts) ->

   Host = binary_to_list(Host0),

   process_flag(trap_exit, true),
   ClientId = case CId of undefined -> <<GId/binary, "_", NId/binary>>; _ -> CId end,

   reconnect_watcher:new(10000, 5, io_lib:format("~s:~p ~p",[Host, Port, ?MODULE])),
   Reconnector = faxe_backoff:new({100, 4200}),
   {ok, Reconnector1} = faxe_backoff:execute(Reconnector, connect),

   connection_registry:reg(NodeId, Host, Port, <<"mqtt">>),
   State = #state{host = Host, port = Port, topic = Topic, dt_field = DTField, dt_format = DTFormat,
      ssl = UseSSL, qos = Qos, client_id = ClientId,
      topics = Topics, include_topic = IncludeTopic, topic_key = TopicKey, as = As,
      reconnector = Reconnector1, user = User, pass = Pass, fn_id = NodeId, ssl_opts = ssl_opts(UseSSL)},
   {ok, State}.

ssl_opts(false) ->
   [];
ssl_opts(true) ->
   faxe_config:get_mqtt_ssl_opts().

process(_In, _, State = #state{}) ->
   {ok, State}.


handle_info(connect, State) ->
   connect(State),
   {ok, State};
handle_info({mqttc, C, connected}, State=#state{host = Host, reconnector = Recon}) ->
   connection_registry:connected(),
   lager:debug("mqtt client connected to ~p",[Host]),
   NewState = State#state{client = C, connected = true, reconnector = faxe_backoff:reset(Recon)},
   subscribe(NewState),
   {ok, NewState};
%% @todo do we have to kill the client ?
handle_info({mqttc, _C,  disconnected}, State=#state{client = Client}) ->
   catch exit(Client, kill),
   connection_registry:disconnected(),
   lager:debug("mqtt client disconnected!!"),
   {ok, State#state{connected = false, client = undefined}};
%% for emqtt
handle_info({publish, #{payload := Payload, topic := Topic} }, S=#state{}) ->
   data_received(Topic, Payload, S);
%% for emqttc
handle_info({publish, Topic, Payload }, S=#state{}) ->
   data_received(Topic, Payload, S);
handle_info({disconnected, shutdown, tcp_closed}=M, State = #state{}) ->
   lager:info("emqtt : ~p", [M]),
   {ok, State};
handle_info({'EXIT', _C, _Reason}, State = #state{reconnector = Recon, host = H, port = P}) ->
   connection_registry:disconnected(),
   lager:notice("EXIT emqtt: ~p [~p]", [_Reason,{H, P}]),
   {ok, Reconnector} = faxe_backoff:execute(Recon, connect),
   {ok, State#state{connected = false, client = undefined, reconnector = Reconnector}};
handle_info(start_debug, State) -> {ok, State#state{debug_mode = true}};
handle_info(stop_debug, State) -> {ok, State#state{debug_mode = false}};
handle_info(What, State) ->
   {ok, State}.

shutdown(#state{client = C}) ->
   catch (emqttc:disconnect(C)).

data_received(Topic, Payload,
    S = #state{dt_field = DTField, dt_format = DTFormat, include_topic = AddTopic, topic_key = TopicKey, as = As}) ->
   node_metrics:metric(?METRIC_BYTES_READ, byte_size(Payload), S#state.fn_id),
   node_metrics:metric(?METRIC_ITEMS_IN, 1, S#state.fn_id),
   Item0 = flowdata:from_json_struct(Payload, DTField, DTFormat),
   dataflow:maybe_debug(item_in, 1, Item0, S#state.fn_id, S#state.debug_mode),
   Item1 =
   case AddTopic of
      true -> flowdata:set_field(Item0, TopicKey, Topic);
      false -> Item0
   end,
   Item = flowdata:set_root(Item1, As),
   {emit, {1, Item}, S}.

connect(State = #state{host = Host, port = Port, client_id = ClientId}) ->
   connection_registry:connecting(),
   reconnect_watcher:bump(),
   Opts0 = [
      {host, Host},
      {port, Port},
      {keepalive, 25},
      {reconnect, 3, 120, 10},
      {client_id, ClientId}
   ],
   Opts1 = opts_auth(State, Opts0),
   Opts = opts_ssl(State, Opts1),
   lager:debug("connect to mqtt broker with: ~p",[Opts]),
   {ok, _Client} = emqttc:start_link(Opts)
.

opts_auth(#state{user = <<>>}, Opts) -> Opts;
opts_auth(#state{user = undefined}, Opts) -> Opts;
opts_auth(#state{user = User, pass = Pass}, Opts) ->
   [{username, User},{password, Pass}] ++ Opts.
opts_ssl(#state{ssl = false}, Opts) -> Opts;
opts_ssl(#state{ssl = true, ssl_opts = SslOpts}, Opts) ->
   [{ssl, SslOpts}]++ Opts.


subscribe(#state{qos = Qos, client = C, topic = Topic, topics = undefined}) when is_binary(Topic) ->
   ok = emqttc:subscribe(C, Topic, Qos);
subscribe(#state{qos = Qos, client = C, topics = Topics}) ->
   TQs = [{Top, Qos} || Top <- Topics],
   ok = emqttc:subscribe(C, TQs).

