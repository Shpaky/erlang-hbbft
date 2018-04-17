-module(hbbft_bba).

-export([init/3, input/2, handle_msg/3]).

-record(bba_data, {
          state = init :: init | waiting | done,
          round = 0,
          secret_key :: tpke_privkey:privkey(),
          coin,
          est :: undefined | 0 | 1,
          output,
          f :: non_neg_integer(),
          n :: pos_integer(),
          witness = sets:new() :: sets:set({non_neg_integer(), 0 | 1}),
          aux_witness = sets:new() :: sets:set({non_neg_integer(), 0 | 1}),
          aux_sent = false :: boolean(),
          broadcasted = sets:new() :: sets:set(0 | 1),
          bin_values = sets:new() :: set:set(0 | 1)
         }).

-type bba_data() :: #bba_data{}.

-export_type([bba_data/0]).

-spec init(tpke_privkey:privkey(), pos_integer(), non_neg_integer()) -> bba_data().
init(SK, N, F) ->
    #bba_data{secret_key=SK, n=N, f=F}.

-spec input(bba_data(), undefined | 0 | 1) -> {bba_data(), ok | {send, [{multicast, {bval, non_neg_integer(), undefined | 0 | 1}}]}}.
input(Data = #bba_data{state=init}, BInput) ->
    {Data#bba_data{est = BInput}, {send, [{multicast, {bval, Data#bba_data.round, BInput}}]}};
input(Data = #bba_data{state=done}, _BInput) ->
    {Data, ok}.

handle_msg(Data = #bba_data{state=done}, _J, _BInput) ->
    {Data, ok};
handle_msg(Data = #bba_data{round=R}, J, {bval, R, V}) ->
    bval(Data, J, V);
handle_msg(Data = #bba_data{round=_R}, J, {aux, _R, V}) ->
    aux(Data, J, V);
handle_msg(Data = #bba_data{round=R, coin=Coin}, J, {{coin, R}, CMsg}) when Coin /= undefined ->
    %% dispatch the message to the nested coin protocol
    case hbbft_cc:handle_msg(Data#bba_data.coin, J, CMsg) of
        {_NewCoin, {result, Result}} ->
            %% ok, we've obtained the common coin
            case sets:size(Data#bba_data.bin_values) == 1 of
                true ->
                    %% if vals = {b}, then
                    [B] = sets:to_list(Data#bba_data.bin_values),
                    Output = case Result rem 2 == B of
                                 true ->
                                     %% if (b = s%2) then output b
                                     B;
                                 false ->
                                     undefined
                             end,
                    case B == Result rem 2 andalso Data#bba_data.output == B of
                        true ->
                            %% we are done
                            {Data, {result, B}};
                        false ->
                            %% increment round and continue
                            NewData = init(Data#bba_data.secret_key, Data#bba_data.n, Data#bba_data.f),
                            input(NewData#bba_data{round=Data#bba_data.round + 1, output=Output}, B)
                    end;
                false ->
                    %% else estr+1 := s%2
                    B = Result rem 2,
                    NewData = init(Data#bba_data.secret_key, Data#bba_data.n, Data#bba_data.f),
                    input(NewData#bba_data{round=Data#bba_data.round + 1}, B)
            end;
        {NewCoin, ok} ->
            {Data#bba_data{coin=NewCoin}, ok}
    end;
handle_msg(Data, _J, _Msg) ->
    {Data, ok}.

-spec bval(bba_data(), non_neg_integer(), 0 | 1) -> {bba_data(), {send, [{multicast, {aux, non_neg_integer(), 0 | 1}}, ... ]}} |
                                                    {bba_data(), {send, [{multicast, {coin, non_neg_integer(), 0 | 1 }}, ...]}}.
bval(Data=#bba_data{n=N, f=F}, Id, V) ->
    %% add to witnesses
    Witness = sets:add_element({Id, V}, Data#bba_data.witness),
    WitnessCount = lists:sum([ 1 || {_, Val} <- sets:to_list(Witness), V == Val ]),
    {NewData, ToSend} = case WitnessCount >= F+1 andalso sets:is_element(V, Data#bba_data.broadcasted) == false of
                            true ->
                                %% add to broadcasted
                                NewData0 = Data#bba_data{witness=Witness,
                                                         broadcasted=sets:add_element(V, Data#bba_data.broadcasted)},
                                {NewData0, [{multicast, {bval, Data#bba_data.round, V}}]};
                            false ->
                                {Data#bba_data{witness=Witness}, []}
                        end,

    case WitnessCount >= 2*F+1 of
        true ->
            %% add to binvalues
            NewData2 = Data#bba_data{witness=Witness,
                                     bin_values=sets:add_element(V, NewData#bba_data.bin_values)},
            {NewData3, ToSend2} = case NewData2#bba_data.aux_sent == false of
                                      true ->
                                          %% XXX How many times do we send AUX per round? I think just once
                                          Random = lists:nth(rand:uniform(sets:size(NewData2#bba_data.bin_values)), sets:to_list(NewData2#bba_data.bin_values)),
                                          {NewData2#bba_data{aux_sent = true}, [{multicast, {aux, NewData2#bba_data.round, Random}}|ToSend]};
                                      false ->
                                          {NewData2, ToSend}
                                  end,
            %% check if we've received at least N - F AUX messages where the values in the AUX messages are member of bin_values
            case sets:size(sets:filter(fun({_, X}) -> sets:is_element(X, NewData3#bba_data.bin_values) end, NewData3#bba_data.aux_witness)) >= N - F of
                true when NewData3#bba_data.coin == undefined ->
                    %% instanciate the common coin
                    %% TODO need more entropy for the SID
                    %% Note: is there a bug here? maybe?
                    {CoinData, {send, CoinSend}} = hbbft_cc:get_coin(hbbft_cc:init(NewData3#bba_data.secret_key, term_to_binary({NewData3#bba_data.round}), N, F)),
                    {NewData3#bba_data{coin=CoinData}, {send, hbbft_utils:wrap({coin, Data#bba_data.round}, CoinSend) ++ ToSend2}};
                _ ->
                    {NewData3, {send, ToSend2}}
            end;
        false ->
            {NewData, {send, ToSend}}
    end.

-spec aux(bba_data(), non_neg_integer(), 0 | 1) -> {bba_data(), ok | {send, [{multicast, {coin, non_neg_integer()}}]}}.
aux(Data = #bba_data{n=N, f=F}, Id, V) ->
    Witness = sets:add_element({Id, V}, Data#bba_data.aux_witness),
    NewData = Data#bba_data{aux_witness = Witness},
    %% check if we've received at least N - F AUX messages where the values in the AUX messages are member of bin_values
    case sets:size(sets:filter(fun({_, X}) -> sets:is_element(X, NewData#bba_data.bin_values) end, NewData#bba_data.aux_witness)) >= N - F of
        true when NewData#bba_data.coin == undefined ->
            %% instanciate the common coin
            %% TODO need more entropy for the SID
            {CoinData, {send, ToSend}} = hbbft_cc:get_coin(hbbft_cc:init(NewData#bba_data.secret_key, term_to_binary({NewData#bba_data.round}), N, F)),
            {NewData#bba_data{coin=CoinData}, {send, hbbft_utils:wrap({coin, Data#bba_data.round}, ToSend)}};
        _ ->
            {NewData, ok}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

kill(Data) ->
    Data#bba_data{state=done}.

init_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, _PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    States = [hbbft_bba:init(Sk, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = input(State, 1),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    io:format("ConvergedResults ~p~n", [ConvergedResults]),
    %% everyone should converge
    ?assertEqual(N, sets:size(ConvergedResults)),
    ok.

init_with_zeroes_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, _PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    States = [hbbft_bba:init(Sk, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    ZeroList = lists:zip([1, 0, 0, 0, 0], StatesWithId),
    %% all valid members should call get_coin
    Res = lists:map(fun({I, {J, State}}) ->
                            {NewState, Result} = input(State, I),
                            {{J, NewState}, {J, Result}}
                    end, ZeroList),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    DistinctResults = sets:from_list([BVal || {result, {_, BVal}} <- sets:to_list(ConvergedResults)]),
    io:format("DistinctResults: ~p~n", [sets:to_list(DistinctResults)]),
    ?assertEqual(N, sets:size(ConvergedResults)),
    ?assertEqual([0], sets:to_list(DistinctResults)),
    ok.

init_with_ones_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, _PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    States = [hbbft_bba:init(Sk, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    OneList = lists:zip([1, 1, 1, 1, 0], StatesWithId),
    %% all valid members should call get_coin
    Res = lists:map(fun({I, {J, State}}) ->
                            {NewState, Result} = input(State, I),
                            {{J, NewState}, {J, Result}}
                    end, OneList),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    DistinctResults = sets:from_list([BVal || {result, {_, BVal}} <- sets:to_list(ConvergedResults)]),
    io:format("DistinctResults: ~p~n", [sets:to_list(DistinctResults)]),
    %% io:format("ConvergedResults ~p~n", [ConvergedResults]),
    ?assertEqual(N, sets:size(ConvergedResults)),
    ?assertEqual([1], sets:to_list(DistinctResults)),
    ok.

init_with_mixed_zeros_and_ones_test() ->
    N = 10,
    F = 2,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, _PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    States = [hbbft_bba:init(Sk, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    MixedList = lists:zip([1, 1, 1, 0, 1, 0, 0, 0, 0, 0], StatesWithId),
    %% all valid members should call get_coin
    Res = lists:map(fun({I, {J, State}}) ->
                            {NewState, Result} = input(State, I),
                            {{J, NewState}, {J, Result}}
                    end, MixedList),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    DistinctResults = sets:from_list([BVal || {result, {_, BVal}} <- sets:to_list(ConvergedResults)]),
    io:format("DistinctResults: ~p~n", [sets:to_list(DistinctResults)]),
    io:format("ConvergedResults ~p~n", [sets:to_list(ConvergedResults)]),
    ?assertEqual(N, sets:size(ConvergedResults)),
    ?assertEqual(1, sets:size(DistinctResults)),
    ok.

one_dead_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, _PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    [S0, S1, S2, S3, S4] = [hbbft_bba:init(Sk, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, kill(S2), S3, S4]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = input(State, 1),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    %% everyone but one should converge
    ?assertEqual(N - 1, sets:size(ConvergedResults)),
    ok.

two_dead_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, _PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    [S0, S1, S2, S3, S4] = [hbbft_bba:init(Sk, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, kill(S2), S3, kill(S4)]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = input(State, 1),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    %% should not converge
    ?assertEqual(0, sets:size(ConvergedResults)),
    ok.
-endif.
