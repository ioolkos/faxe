%% Date: 05.01.17 - 17:41
%% Ⓒ 2019 heyoka
%% @doc
%% rewrite of window with queue module
%% this window holds "period" events and emits every "every" incoming event
%% with the "fill_period" option given, the window will only emit full windows
%%
-module(esp_win_event).
-author("Alexander Minichmair").

-behaviour(df_component).

-include("faxe.hrl").

%% API
-export([init/3, process/3, handle_info/2, options/0, wants/0, emits/0]).

-record(state, {
   every,
   period,
   window :: queue:queue(),
   length = 0,
   count = 0,
   at = 0,
   len = 0,
   fill_period
}).

options() ->
   [{period, integer, undefined}, {every, integer, 4}, {fill_period, is_set}].

wants() -> point.
emits() -> batch.

init(_NodeId, _Inputs, #{period := Period0, every := Every, fill_period := Fill}) ->
   Period = case Period0 of undefined -> Every; _ -> Period0 end,
   %% fill_period does not make sense, if every is less than period
   DoFill = (Fill == true) andalso (Period > Every),
   State = #state{every = Every, period = Period, fill_period = DoFill, window = queue:new()},
   {ok, all, State}.

process(_Inport, #data_point{} = Point, State=#state{} ) ->
   NewState = accumulate(Point, State),
   EvictState = maybe_evict(NewState),
   maybe_emit(EvictState).

handle_info(_Request, State) ->
   {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
accumulate(Point = #data_point{}, State = #state{window = Win, count = C, at = At, len = Len}) ->
   State#state{count = C+1, at = At+1, len = Len+1, window = queue:in(Point, Win)}.

maybe_emit(State = #state{every = Count, count = Count}) ->
   maybe_do_emit(State#state{count = 0});
maybe_emit(State = #state{}) ->
   {ok, State}.

maybe_do_emit(State = #state{fill_period = true, len = Period, period = Period}) ->
   do_emit(State);
maybe_do_emit(State = #state{fill_period = false}) ->
   do_emit(State);
maybe_do_emit(State = #state{}) ->
   {ok, State}.

do_emit(State=#state{window = Win, count = _Count, len = _Len}) ->
   Batch = #data_batch{points = queue:to_list(Win)},
   {emit, Batch, State}.


maybe_evict(State = #state{period = Period, at = At, len = Len, window = Win}) when At == Period+1 ->
   NewWin = queue:drop(Win),
   State#state{at = Period, len = Len-1, window = NewWin};
maybe_evict(Win = #state{}) ->
   Win.


