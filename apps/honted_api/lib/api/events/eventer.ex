#   Copyright 2018 OmiseGO Pte Ltd
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

defmodule HonteD.API.Events.Eventer do
  @moduledoc """
  Handles stream of send events from HonteD.ABCI and forwards them to subscribers.

  Generic process registries are a bad fit since we want to hyper-optimize for
  particular use case (bloom filters etc).
  """
  use GenServer
  require Logger

  alias HonteD.API.Events.Replay, as: Replay
  alias HonteD.API.Transaction

  defmodule State do
    @moduledoc """
    Internal state of the Eventer genserver - holds the state of processing of the events
    """
    defstruct [subs: BiMultiMap.new(),
               filters: BiMultiMap.new(),
               pending_filters: [],
               monitors: Map.new(),
               committed: Map.new(),
               height: 0,
               tendermint: HonteD.API.Tendermint.RPC,
              ]
    @typedoc """
    Many-to-many relation between lists of topics and subscribers' pids.
    """
    @type subs :: BiMultiMap.t([topic], pid)
    @typedoc """
    Stores filters - one for each call to new_send_filter; history filters are not stored here.
    BiMultiMap is used instead of pair of maps because of convenience.
    """
    @type filters :: BiMultiMap.t(HonteD.filter_id, {[topic], pid})
    @typep topic :: HonteD.address
    @typep token :: HonteD.token

    @type t :: %State{
      subs: subs,
      filters: filters,
      # New filter sends transaction from block boundary. Before the next block is mined, filter is
      # being kept in this list.
      pending_filters: [{HonteD.filter_id, pid, [topic]}],
      # We monitor subscribers' pids to GC memory occupied by filters.
      monitors: %{pid => reference},
      # Events that are waiting to be finalized.
      # Assumes one source of finality for each of the tokens.
      # Works ONLY for Send transactions
      committed: %{optional(token) => Transaction.Finality.event_queue},
      height: HonteD.block_height,
      tendermint: module(),
    }
  end

  defmodule EventContentTx do
    @moduledoc """
    Transaction and it's tendermint-hash bound together, which are what gets pushed to the subscribers
    """
    defstruct [:tx, :hash]
  end

  def start_link(args, opts) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def child_spec(_) do
    %{id: __MODULE__,
      start: {__MODULE__, :start_link, [[], [name: __MODULE__]]},
      type: :worker,
      restart: :permanent,
    }
  end

  @doc """
  Transforms an Eventer-internal event representation of an event and pushes it out to the subscribed
  listeners

  for transactions, the Eventer-internal event representation is the signed transaction itself
  """
  @spec do_notify(:finalized | :committed, HonteD.Transaction.SignedTx.t, pos_integer, State.subs, State.filters)
    :: :ok
  def do_notify(finality_status, %HonteD.Transaction.SignedTx{raw_tx: tx} = signed, event_height, subs, filters) do
    # NOTE: we need to enrich the event with a Tendermint-specific hash here for reference
    #       albeit not perfect, this seems like the best place to do it
    event_content = %EventContentTx{tx: tx, hash: signed
                                                  |> HonteD.TxCodec.encode
                                                  |> HonteD.API.Tendermint.Tx.hash
    }

    event_topics = event_topics_for(tx)
    pids = subscribed(event_topics, subs, filters)

    _ = Logger.debug(fn -> "do_notify: #{inspect event_topics} #{inspect finality_status}, " <>
                           "#{inspect event_content}, pid: #{inspect pids}" end)
    for {filter_id, pid} <- pids do
      msg = message(finality_status, event_height, filter_id, event_content)
      send(pid, {:event, msg})
    end
    :ok
  end

  # handles composing of the final map with contents of what gets pushed to subscribers
  defp message(finality_status, height, filter_id, %EventContentTx{} = event_content)
  when finality_status in [:committed, :finalized] do
    %{source: filter_id, height: height, finality: finality_status, transaction: event_content}
  end

  def stream_end_msg(filter_id) do
    %{source: filter_id, data: "replay finished"}
  end

  ## callbacks

  @spec init([] | [%{tendermint: module}]) :: {:ok, %State{}}
  def init([]), do: {:ok, %State{}}
  def init([%{tendermint: module}]), do: {:ok, %State{tendermint: module}}

  def handle_cast({:event, %HonteD.Transaction.SignedTx{raw_tx: %HonteD.Transaction.Send{}} = signed}, state) do
    state = insert_committed(signed, state)
    do_notify(:committed, signed, state.height, state.subs, state.filters)
    {:noreply, state}
  end

  def handle_cast({:event, %HonteD.API.Events.NewBlock{} = event}, state) do
    state = process_pending_filters(state)
    {:noreply, %{state | height: event.height}}
  end

  def handle_cast({:event_context,
                   %HonteD.Transaction.SignedTx{raw_tx: %HonteD.Transaction.SignOff{} = event}, tokens},
                  state)
  when is_list(tokens) do
    case check_valid_signoff?(event, state.tendermint) do
      true ->
        {:noreply, finalize_events(tokens, event.height, state)}
      false ->
        _ = Logger.debug(fn -> "Dropped sign-off: #{inspect event}, #{inspect tokens}" end)
        {:noreply, state}
    end
  end

  def handle_cast({:event_context, event, context}, state) do
    _ = Logger.warn(fn -> "Warning: unhandled event #{inspect event} with context #{inspect context}" end)
    {:noreply, state}
  end

  def handle_cast({:event, event}, state) do
    _ = Logger.warn(fn -> "Warning: unhandled event #{inspect event} without context" end)
    {:noreply, state}
  end

  def handle_cast(msg, state) do
    {:stop, {:unhandled_cast, msg}, state}
  end

  def handle_call({:new_filter, topics, pid}, _from, state) do
    filter_id = make_filter_id()
    {:reply,
     {:ok, %{new_filter: filter_id, start_height: state.height + 1}},
     %{state | pending_filters: [{filter_id, topics, pid} | state.pending_filters]}
    }
  end

  def handle_call({:new_filter_history, topics, pid, first, last}, _from, state) do
    filter_id = make_filter_id()
    _ = Logger.warn("tendermint module is: #{inspect state.tendermint}")
    _ = Replay.spawn(filter_id, state.tendermint, first..last, topics, pid)
    {:reply, {:ok, %{history_filter: filter_id}}, state}
  end

  def handle_call({:drop_filter, filter_id}, _from, state) do
    case BiMultiMap.get(state.filters, filter_id, nil) do
      [{topics, pid}] ->
        state = drop_filter(filter_id, topics, pid, state)
        {:reply, :ok, state}
      nil ->
        case List.keytake(state.pending_filters, filter_id, 0) do
          nil ->
            {:reply, {:error, :notfound}, state}
          {_, new_pending} ->
            {:reply, :ok, %{state | pending_filters: new_pending}}
        end
    end
  end

  def handle_call({:status, filter_id}, _from, state) do
    case {BiMultiMap.get(state.filters, filter_id),
          List.keyfind(state.pending_filters, filter_id, 0)} do
      {[], nil} ->
        {:reply, {:error, :notfound}, state}
      {[{topics, _}], _} ->
        {:reply, {:ok, topics}, state}
      {_, {_, topics, _}} ->
        {:reply, {:ok, topics}, state}
    end
  end

  def handle_call(msg, from, state) do
    {:stop, {:unhandled_call, from, msg}, state}
  end

  def handle_info({:DOWN, _monref, :process, pid, _reason},
                  %{subs: subs, monitors: mons} = state) do
    mons = Map.delete(mons, pid)
    topics = BiMultiMap.get_keys(subs, pid)
    subs = BiMultiMap.delete_value(subs, pid)
    drop_filter_ids = fn(topics_group, acc) ->
      BiMultiMap.delete_value(acc, {topics_group, pid})
    end
    filters = Enum.reduce(topics, state.filters, drop_filter_ids)
    {:noreply, %{state | subs: subs, monitors: mons, filters: filters}}
  end

  def handle_info(msg, state) do
    {:stop, {:unhandled_info, msg}, state}
  end

  ## internals

  # New filters are activated on block boundary; before that they are stored in pending_filters.
  # This is a cleaner approach than starting to emit events in the middle of the block.
  defp process_pending_filters(state) do
    state = Enum.reduce(state.pending_filters, state, &apply_filter/2)
    %{state | pending_filters: []}
  end

  defp apply_filter({filter_id, topics, pid}, state)
  when is_pid(pid) and is_list(topics) do
    mons = Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)
    filters = BiMultiMap.put(state.filters, filter_id, {topics, pid})
    subs = BiMultiMap.put(state.subs, topics, pid)
    %{state | subs: subs, monitors: mons, filters: filters}
  end

  defp drop_filter(filter_id, topics, pid, state) do
    filters = BiMultiMap.delete(state.filters, filter_id, {topics, pid})
    subs = BiMultiMap.delete(state.subs, topics, pid)
    mons = case BiMultiMap.has_value?(subs, pid) do
             false ->
               state.monitors
             true ->
               Process.demonitor(state.monitors[pid], [:flush])
               Map.delete(state.monitors, pid)
           end
    %{state | subs: subs, monitors: mons, filters: filters}
  end

  defp finalize_events(tokens, signoff_height, state) do
    notify_token = fn(token, acc_committed) ->
      # for a given token will process the queue with events and emit :finalized events to subscribers
      {events, acc_committed} = pop_finalized(token, signoff_height, acc_committed)
      _ = for {height, event} <- events,
        do: do_notify(:finalized, event, height, state.subs, state.filters)
      acc_committed
    end
    %{state | committed: Enum.reduce(tokens, state.committed, notify_token)}
  end

  defp insert_committed(event, state) do
    token = get_token(event)
    enqueue = fn(queue) -> Qex.push(queue, {state.height, event}) end
    committed = Map.update(state.committed, token, Qex.new([{state.height, event}]), enqueue)
    %{state | committed: committed}
  end

  defp pop_finalized(token, signed_off_height, committed) do
    split_queue_by_finalized_status = fn
      # should take a queue and split it into a list of finalized events and
      # a queue with the rest of {height, event}'s
      (nil) -> {[], nil}
      (queue) -> Transaction.Finality.split_finalized_events(queue, signed_off_height)
    end
    Map.get_and_update(committed, token, split_queue_by_finalized_status)
  end

  def check_valid_signoff?(%HonteD.Transaction.SignOff{} = event, tendermint_module) do
    client = tendermint_module.client()
    with {:ok, blockhash} <- HonteD.API.Tools.get_block_hash(event.height, tendermint_module, client),
      do: Transaction.Finality.valid_signoff?(event.hash, blockhash)
  end

  defp get_token(%HonteD.Transaction.SignedTx{raw_tx: %HonteD.Transaction.Send{} = event}) do
    event.asset
  end

  defp event_topics_for(%HonteD.Transaction.Send{to: dest}), do: [dest]
  defp event_topics_for(_), do: []

  defp subscribed(topics, subs, filters) do
    pids = BiMultiMap.get(subs, topics)
    for pid <- pids do
      [filter_id] = BiMultiMap.get_keys(filters, {topics, pid})
      {filter_id, pid}
    end
  end

  defp make_filter_id do
    make_ref()
    |> :erlang.term_to_binary
    |> HonteD.Crypto.hash
  end

end
