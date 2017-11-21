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
  require Tesla

  def client() do
    rpc_port = Application.get_env(:honted_api, :tendermint_rpc_port)
    Tesla.build_client [
      {Tesla.Middleware.BaseUrl, "http://localhost:#{rpc_port}"},
      Tesla.Middleware.JSON
    ]
  end

  def broadcast_tx_sync(client, tx) do
    Tesla.get(client, "/broadcast_tx_sync", query: encode(
      tx: tx
    ))
    |> decode_jsonrpc
  end

  def broadcast_tx_commit(client, tx) do
    Tesla.get(client, "/broadcast_tx_commit", query: encode(
      tx: tx
    ))
    |> decode_jsonrpc
  end

  def abci_query(client, data, path) do
    Tesla.get(client, "abci_query", query: encode(
      data: data,
      path: path
    ))
    |> decode_jsonrpc
    |> decode_abci_query
  end

  def tx(client, hash) do
    Tesla.get(client, "tx", query: encode(
      hash: {:hash, hash},
      prove: false
    ))
    |> decode_jsonrpc
    |> decode_tx
  end
  
  ### private - tendermint rpc's specific encoding/decoding

  defp decode_jsonrpc(response) do
    case response.body do
      %{"error" => "", "result" => result} -> {:ok, result}
      %{"error" => error, "result" => nil} -> {:error, error}
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
  
  defp encode(arglist) when is_list(arglist) do
    arglist
    |> Enum.map(fn {argname, argval} -> {argname, encode(argval)} end)
  end
  defp encode({:hash, raw}) when is_binary(raw), do: "0x#{raw}"
  defp encode(raw) when is_binary(raw), do: "\"#{raw}\""
  defp encode(raw) when is_boolean(raw), do: to_string(raw)
  
end