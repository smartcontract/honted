defmodule HonteD.Eth.WaitFor do
  @moduledoc """
  Generic wait_for_* utils, styled after web3 counterparts
  """
  import Ethereumex.HttpClient

  def rpc() do
    f = fn() ->
      IO.puts("before eth_syncing")
      {:ok, false} = eth_syncing()
      IO.puts("after good eth_syncing")
      {:ok, :ready}
    end
    function(fn() -> repeat_until_ok(f) end, 10_000)
  end

  def block_height(n, dev \\ false, timeout \\ 10_000) do
    f = fn() ->
      height = HonteD.Eth.Contract.block_height()
      IO.puts("current height: #{inspect height}; n: #{n}")
      case height < n do
        true ->
          maybe_mine(dev)
          :repeat
        false ->
          {:ok, height}
      end
    end
    rf = fn() -> repeat_until_ok(f) end
    function(rf, timeout)
  end

  def receipt(txhash, timeout) do
    f = fn() ->
      case eth_get_transaction_receipt(txhash) do
        {:ok, receipt} when receipt != nil -> {:ok, receipt}
        _ -> :repeat
      end
    end
    rf = fn() -> repeat_until_ok(f) end
    function(rf, timeout)
  end

  def function(f, timeout) do
    f
    |> Task.async
    |> Task.await(timeout)
  end

  def repeat_until_ok(f) do
    try do
      {:ok, _} = f.()
    catch
      something ->
        Process.sleep(100)
        repeat_until_ok(f)
      :error, {:badmatch, _} = error ->
        Process.sleep(100)
        repeat_until_ok(f)
    end
  end

  defp maybe_mine(false), do: :noop
  defp maybe_mine(true) do
    {:ok, [addr | _]} = eth_accounts()
    {:ok, txhash} = eth_send_transaction(%{from: addr, to: addr, value: "0x1"})
    {:ok, receipt} = receipt(txhash, 1_000)
  end
end
