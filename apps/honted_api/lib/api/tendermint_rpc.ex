defmodule HonteD.API.TendermintRPC do
  @moduledoc """
  Wraps Tendermints RPC to allow to broadcast transactions from Elixir functions, inter alia

  This should only depend on Tendermint rpc's specs, never on any of our stuff. Thus it only does the Base16/64
  decoding, and the Poison decoding of e.g. query responses happens elsewhere.

  The sequence of every call to the RPC is:
    - incoming request from Elixir
    - encode the query using `encode` for their respective types
    - send request to json rpc via Tesla
    - decode jsonrpc response via `decode_jsonrpc`
    - additional decoding depending on the particular request/response (the `case do`)
  """

  @behaviour HonteD.API.TendermintBehavior

  defmodule Websocket do
    @moduledoc """
    Genserver implementing application-wide reused connection to the Tendermint RPC via JSONRPC over Websocket
    """
    use GenServer
    @rpc_timeout 100_000

    def start_link(opts) do
      GenServer.start(__MODULE__, :ok, opts)
    end

    def init(:ok) do
      {:ok, nil}
    end

    def call_method(method, params) do
      GenServer.call(__MODULE__, {:call, method, params}, @rpc_timeout)
    end

    def handle_call({:call, method, params}, _from, websocket) do
      websocket = if websocket == nil, do: Websocket.connect!, else: websocket
      case sendrecv!(websocket, method, params) do
        {:ok, response} -> {:reply, Poison.decode!(response), websocket}
        {:error, error} -> {:stop, %{reason: error}, websocket}
      end
    end

    def connect!() do
      rpc_port = Application.get_env(:honted_api, :tendermint_rpc_port)
      Socket.Web.connect!("localhost", rpc_port, path: "/websocket")
    end

    def send!(websocket, method, params) when is_atom(method) and is_map(params) do
      encoded_message = Poison.encode!(%{jsonrpc: "2.0", id: "0", method: method, params: params})
      websocket
      |> Socket.Web.send!({
        :text,
        encoded_message
      })
    end

    def recv!(websocket) do
      case Socket.Web.recv!(websocket) do
        {:text, response} -> {:ok, response}
        {:ping, ""} -> recv!(websocket)
      end
    end

    def sendrecv!(websocket, method, params) when is_atom(method) and is_list(params) do
      :ok = Websocket.send!(websocket, method, Map.new(params))
      Websocket.recv!(websocket)
    end
  end

  @impl true
  def client, do: nil

  @impl true
  def broadcast_tx_async(_client, tx) do
    :broadcast_tx_async
    |> Websocket.call_method([tx: tx |> Base.encode64])
    |> decode_jsonrpc
  end

  @impl true
  def broadcast_tx_sync(_client, tx) do
    :broadcast_tx_sync
    |> Websocket.call_method([tx: tx |> Base.encode64])
    |> decode_jsonrpc
  end

  @impl true
  def broadcast_tx_commit(_client, tx) do
    :broadcast_tx_commit
    |> Websocket.call_method([tx: tx |> Base.encode64])
    |> decode_jsonrpc
  end

  @impl true
  def abci_query(_client, data, path) do
    :abci_query
    |> Websocket.call_method([data: data, path: path])
    |> decode_jsonrpc
    |> decode_abci_query
  end

  @impl true
  def tx(_client, hash) do
    :tx
    |> Websocket.call_method([hash: hash |> Base.decode16! |> Base.encode64, prove: false])
    |> decode_jsonrpc
    |> decode_tx
  end

  @impl true
  def block(_client, height) do
    {:ok, block} =
      :block
      |> Websocket.call_method([height: height])
      |> decode_jsonrpc
    {:ok, update_in(block, ["block", "data", "txs"],
                    fn(txs) -> Enum.map(txs, &Base.decode64!/1) end)}
  end

  ### private - tendermint rpc's specific encoding/decoding

  defp decode_jsonrpc(response) do
    case response do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
    end
  end

  defp decode_abci_query({:ok, result}) do
    {:ok, result
          |> update_in(["response", "value"], &Base.decode16!/1)}
  end
  defp decode_abci_query(other), do: other

  defp decode_tx({:ok, result}) do
    {:ok, result
          |> Map.update!("tx", &Base.decode64!/1)}
  end
  defp decode_tx(other), do: other
end
