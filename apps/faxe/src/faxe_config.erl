%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 10. Mär 2020 21:16
%%%-------------------------------------------------------------------
-module(faxe_config).
-author("heyoka").

%% API
-export([
   get/1, get/2,
   q_file/1,
   get_mqtt_ssl_opts/0, get_amqp_ssl_opts/0]).

get(Key) ->
   application:get_env(faxe, Key, undefined).

get(Key, Default) ->
   application:get_env(faxe, Key, Default).

%% @doc get the base dir for esq q-files
q_file({GraphId, NodeId}) when is_binary(GraphId) andalso is_binary(NodeId) ->
   EsqBaseDir = faxe_config:get(esq_base_dir),
   binary_to_list(
      filename:join([EsqBaseDir, GraphId, NodeId])
   ).

%% ssl options
get_mqtt_ssl_opts() ->
   get_ssl_opts(mqtt).
get_amqp_ssl_opts() ->
   get_ssl_opts(amqp).
get_ssl_opts(Key) when is_atom(Key) ->
   case faxe_config:get(Key) of
      KeyOpts when is_list(KeyOpts) ->
         SslOpts = proplists:get_value(ssl, KeyOpts, []),
         proplists:delete(enable, SslOpts);
      _ -> []
   end.
