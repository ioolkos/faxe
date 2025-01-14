.PHONY: dev1 start dev2 dev3 remsh

dev1:
	export FAXE_EXTENSIONS=/home/heyoka/workspace/faxe/extensions.config && \
	export FAXE_DFS_SCRIPT_PATH=/home/heyoka/workspace/faxe/dfs/ && \
	export FAXE_PYTHON_SCRIPT_PATH=/home/heyoka/workspace/faxe/python/ && \
	export FAXE_QUEUE_BASE_DIR=/home/heyoka/esq_data/ && \
	export FAXE_MNESIA_DIR=./mnesia_data && \
	export FAXE_QUEUE_CAPACITY=50 && \
	export FAXE_DEQUEUE_INTERVAL=3ms && \
	export FAXE_DEQUEUE_MIN_INTERVAL=1ms && \
	export FAXE_DEQUEUE_MAX_INTERVAL=600ms && \
	export FAXE_CRATE_HTTP_TLS_ENABLE=off && \
	export FAXE_CRATE_HTTP_HOST='10.14.204.10' && \
	export FAXE_CRATE_HTTP_PORT=4200 && \
	export FAXE_CRATE_HTTP_USER=faxedevuhw873 && \
	export FAXE_CRATE_HTTP_PASS=sD7YAu6qrENaYpYzUpZT && \
	export FAXE_CRATE_HOST='10.14.204.10' && \
    #export FAXE_CRATE_PORT=4200 && \
    export FAXE_CRATE_USER=faxedevuhw873 && \
    export FAXE_CRATE_PASS=sD7YAu6qrENaYpYzUpZT && \
	export FAXE_MQTT_HOST=10.10.1.102 && \
	export FAXE_MQTT_SSL_ENABLE=off && \
	export FAXE_AMQP_HOST=10.14.204.28 && \
	export FAXE_AMQP_USER=miae && \
	export FAXE_AMQP_PASS=tgw2019 && \
	export FAXE_LOG_LOGSTASH_BACKEND_ENABLE=on && \
	export FAXE_LOG_LOGSTASH_LEVEL=notice && \
	export FAXE_LOG_LOGSTASH_HOST=10.14.204.17 && \
	export FAXE_LOG_LOGSTASH_PORT=9125 && \
	export FAXE_LOG_LOGSTASH_BACKEND_PROTOCOL=udp && \
	export FAXE_FLOW_AUTO_START=off && \
	export FAXE_FLOW_AUTO_RELOAD=off && \
	export FAXE_ALLOW_ANONYMOUS=true && \
	export FAXE_HTTP_API_TLS_ENABLE=off && \
	export FAXE_CONN_STATUS_HANDLER_MQTT_ENABLE=on && \
	export FAXE_METRICS_HANDLER_MQTT_ENABLE=on && \
	export FAXE_FLOW_CHANGED_HANDLER_MQTT_ENABLE=off && \
	export FAXE_DEBUG_HANDLER_MQTT_ENABLE=on && \
	export FAXE_DEBUG_HANDLER_MQTT_BASE_TOPIC=tgw/sys/faxe/ && \
	export FAXE_HOST=heyoka_local && \
	export FAXE_S7POOL_ENABLE=on && \
	rebar3 as dev1 release && _build/dev1/rel/faxe/bin/faxe console

start:
	export FAXE_DFS_SCRIPT_PATH=/home/heyoka/workspace/faxe/dfs/ && \
    export FAXE_QUEUE_BASE_DIR=/home/heyoka/esq_data/ && \
	_build/dev1/rel/faxe/bin/faxe console

dev2:
	rebar3 as dev2 release && _build/dev2/rel/faxe/bin/faxe console

dev3:
	rebar3 as dev3 release && _build/dev3/rel/faxe/bin/faxe console

dev4:
	rebar3 as dev4 release && _build/dev4/rel/faxe/bin/faxe console

dev5:
	rebar3 as dev5 release && _build/dev5/rel/faxe/bin/faxe console

rmsh:
	erl -sname rm -remsh faxe1@ubuntu -setcookie distrepl_proc_cookie