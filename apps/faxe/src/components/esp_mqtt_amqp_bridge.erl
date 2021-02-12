%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2019, <COMPANY>
%%% @doc
%%% Receive data from an mqtt-broker.
%%% @end
%%% Created : 27. May 2019 09:00
%%%-------------------------------------------------------------------
-module(esp_mqtt_amqp_bridge).
-author("heyoka").

%% API
-behavior(df_component).

-include("faxe.hrl").
%% API
-export([init/3, process/3, options/0, handle_info/2, shutdown/1, check_options/0, metrics/0, data_received/3]).

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
   ssl = false,
   ssl_opts = [],
   fn_id,

   %% AMQP
   amqp_opts,
   amqp_vhost,
   amqp_exchange,
   amqp_routing_key,
   amqp_ssl = false,

   %% other
   queues = #{},
   amqp_publisher = #{}
   }).

options() -> [
   %% MQTT
   {host, binary, {mqtt, host}},
   {port, integer, {mqtt, port}},
   {user, string, {mqtt, user}},
   {pass, string, {mqtt, pass}},
   {qos, integer, 1},
   {topic, binary, undefined},
   {topics, binary_list, undefined},
   {ssl, is_set},
   %% AMQP
   {amqp_host, string, {amqp, host}},
   {amqp_port, integer, {amqp, port}},
   {amqp_user, string, {amqp, user}},
   {amqp_pass, string, {amqp, pass}},
   {amqp_vhost, string, <<"/">>},
   {amqp_exchange, string, <<"x">>},
   {amqp_routing_key, string, <<"">>},
   {amqp_ssl, is_set, false}

].

check_options() ->
   [
      {one_of_params, [topic, topics]}
   ].

metrics() ->
   [
      {?METRIC_SENDING_TIME, histogram, [slide, 60], "Network time for sending a message."},
      {?METRIC_BYTES_READ, meter, [], "Size of item sent in kib."}
   ].

init(NodeId, _Ins,
   #{ host := Host0, port := Port, topic := Topic, topics := Topics, user := User, pass := Pass,
      ssl := UseSSL, qos := Qos,
      %% AMQP
      amqp_host := AMQPHost0, amqp_port := AMQPPort, amqp_user := AMQPUser, amqp_pass := AMQPPass,
      amqp_vhost := AMQPVHost, amqp_exchange := AMQPEx, amqp_routing_key := AMQPRoutingKey,
      amqp_ssl := AMQPUseSSL

      } = _Opts) ->

   %% AMQP
   AMQPOpts = #{
      host => binary_to_list(AMQPHost0), port => AMQPPort, user => AMQPUser,
      pass => AMQPPass, vhost => AMQPVHost, exchange => AMQPEx,
      routing_key => AMQPRoutingKey, ssl => AMQPUseSSL
   },

   %% MQTT
   Host = binary_to_list(Host0),
   process_flag(trap_exit, true),
   ClientId = list_to_binary(faxe_util:uuid_string()),

   reconnect_watcher:new(10000, 5, io_lib:format("~s:~p ~p",[Host, Port, ?MODULE])),
   Reconnector = faxe_backoff:new({5,1200}),
   {ok, Reconnector1} = faxe_backoff:execute(Reconnector, connect_mqtt),

   connection_registry:reg(NodeId, Host, Port, <<"mqtt">>),

   State = #state{
      amqp_opts = AMQPOpts, amqp_exchange = AMQPEx, amqp_routing_key = AMQPRoutingKey,

      host = Host, port = Port, topic = Topic, ssl = UseSSL, qos = Qos,
      client_id = ClientId, topics = Topics, reconnector = Reconnector1, user = User,
      pass = Pass, fn_id = NodeId, ssl_opts = ssl_opts(UseSSL)},
   {ok, State}.

ssl_opts(false) ->
   [];
ssl_opts(true) ->
   faxe_config:get_mqtt_ssl_opts().

process(_In, _, State = #state{}) ->
   {ok, State}.


handle_info(connect_mqtt, State) ->
   connect_mqtt(State),
   {ok, State};
handle_info({mqttc, C, connected}, State=#state{}) ->
   connection_registry:connected(),
   lager:notice("mqtt client connected!!"),
   NewState = State#state{client = C, connected = true},
   subscribe(NewState),
   {ok, NewState};
handle_info({mqttc, _C,  disconnected}, State=#state{client = Client}) ->
   catch exit(Client, kill),
   connection_registry:disconnected(),
   lager:debug("mqtt client disconnected!!"),
   {ok, State#state{connected = false, client = undefined}};
%% for emqtt
handle_info({publish, #{payload := Payload, topic := Topic} }, S=#state{}) ->
   m_data_received(Topic, Payload, S);
%% for emqttc
handle_info({publish, Topic, Payload }, S=#state{}) ->
   m_data_received(Topic, Payload, S);
handle_info({disconnected, shutdown, tcp_closed}=M, State = #state{}) ->
   lager:warning("emqtt : ~p", [M]),
   {ok, State};
handle_info({'EXIT', _C, _Reason}, State = #state{reconnector = Recon, host = H, port = P}) ->
   connection_registry:disconnected(),
   lager:warning("EXIT emqtt: ~p [~p]", [_Reason,{H, P}]),
   {ok, Reconnector} = faxe_backoff:execute(Recon, connect_mqtt),
   {ok, State#state{connected = false, client = undefined, reconnector = Reconnector}};
handle_info({'DOWN', _MonitorRef, process, Client, _Info}, #state{amqp_publisher = Pubs} = State) ->
   PublisherList = maps:to_list(Pubs),
   {Topics, Pids} = lists:unzip(PublisherList),
   NewState =
   case lists:member(Client, Pids) of
      true ->
         Flipped = lists:zip(Pids, Topics),
         Topic = proplists:get_value(Client, Flipped),
         start_amqp_connection(Topic, State);
      false -> State
   end,
   lager:notice("AMQP-PubWorker ~p is 'DOWN' Info:~p", [Client, _Info]),
   {ok, NewState};
handle_info({publisher_ack, Ref}, State) ->
   lager:notice("message acked: ~p",[Ref]),
   {ok, State};
handle_info(What, State) ->
   lager:warning("~p handle_info: ~p", [?MODULE, What]),
   {ok, State}.

%% @todo shutdown esq queues ?
shutdown(#state{client = C, amqp_publisher = Pubs}) ->
   [catch (bunny_esq_worker:stop(CPub)) || {_T, CPub} <- maps:to_list(Pubs)],
   catch (emqttc:disconnect(C)).

m_data_received(Topic, Payload, State) ->
   {TimeMy, Res} = timer:tc(?MODULE, data_received, [Topic, Payload, State]),
   lager:info("Time to process Payload: ~p",[TimeMy]),
   Res.

data_received(Topic, Payload, S = #state{queues = Queues, amqp_exchange = Exchange })
      when is_map_key(Topic, Queues) ->
   Q = maps:get(Topic, Queues),
   RK = topic_to_key(Topic),
%%   lager:notice("got data with topic: ~p and enqueue with routingkey :~p",[Topic, RK]),
   ok = esq:enq({Exchange, RK, Payload, []}, Q),
   {ok, S};
data_received(Topic, Payload, S = #state{}) ->
   lager:warning("start new queue and publisher: ~p",[Topic]),
   NewState0 = start_queue(Topic, S),
   NewState = start_amqp_connection(Topic, NewState0),
   data_received(Topic, Payload, NewState).

start_amqp_connection(Topic, State = #state{amqp_opts = Opts, amqp_publisher = Pubs, queues = Queues}) ->
   Q = maps:get(Topic, Queues),
   {ok, Pid} = bunny_esq_worker:start(Q, Opts),
   erlang:monitor(process, Pid),
   NewPublishers = Pubs#{Topic => Pid},
   State#state{amqp_publisher = NewPublishers}.

start_queue(Topic, State = #state{fn_id = {FlowId, NodeId}, queues = Queues}) ->
   Key = topic_to_key(Topic),
   QFile = faxe_config:q_file({FlowId, <<NodeId/binary, "-", Key/binary>>}),
   {ok, Q} = esq:new(QFile, [{tts, 300}, {capacity, 10}, {ttf, 20000}]),
   NewQueues = Queues#{Topic => Q},
   State#state{queues = NewQueues}.

connect_mqtt(State = #state{host = Host, port = Port, client_id = ClientId}) ->
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
   lager:info("connect to mqtt broker with: ~p",[Opts]),
   {ok, _Client} = emqttc:start_link(Opts)
.

topic_to_key(Topic) when is_binary(Topic) ->
   binary:replace(Topic, <<"/">>, <<".">>, [global]).

opts_auth(#state{user = <<>>}, Opts) -> Opts;
opts_auth(#state{user = undefined}, Opts) -> Opts;
opts_auth(#state{user = User, pass = Pass}, Opts) ->
   [{username, User},{password, Pass}] ++ Opts.
opts_ssl(#state{ssl = false}, Opts) -> Opts;
opts_ssl(#state{ssl = true, ssl_opts = SslOpts}, Opts) ->
   [{ssl, SslOpts}]++ Opts.


subscribe(#state{qos = Qos, client = C, topic = Topic, topics = undefined}) when is_binary(Topic) ->
   lager:notice("mqtt_client subscribe: ~p", [Topic]),
   ok = emqttc:subscribe(C, Topic, Qos);
subscribe(#state{qos = Qos, client = C, topics = Topics}) ->
   TQs = [{Top, Qos} || Top <- Topics],
   ok = emqttc:subscribe(C, TQs).

