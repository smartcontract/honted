defmodule HonteD.ABCITest do
  @moduledoc """
  **NOTE** this test will pretend to be Tendermint core
  """
  use ExUnit.Case, async: true
  doctest HonteD

  import HonteD.ABCI

  setup do
    {:ok, state} = HonteD.ABCI.init(:ok)
    
    # FIXME: should avoid using HonteD.Crypto in favor of HonteD.API (multiple places)
    # remove HonteD.Crypto usage as HonteD.API gets implemented
    {:ok, alice_priv} = HonteD.Crypto.generate_private_key
    {:ok, alice_pub} = HonteD.Crypto.generate_public_key(alice_priv)
    {:ok, alice} = HonteD.Crypto.generate_address(alice_pub)
    
    {:ok, bob} = with {:ok, priv} <- HonteD.Crypto.generate_private_key,
                      {:ok, pub} <- HonteD.Crypto.generate_public_key(priv),
                      do: HonteD.Crypto.generate_address(pub)
    {:ok, state: state,
          alice_info: %{priv: alice_priv, addr: alice},
          bob_info: %{addr: bob}}
  end
  
  setup :issue_5_to_alice
  
  defp issue_5_to_alice(%{state: state, alice_info: alice} = context) do
    if context[:alice_has_5] do
      {:reply, _, state} =
        handle_call({:RequestDeliverTx, "ISSUE asset 5 #{alice.addr}"}, nil, state)
      %{context | state: state}
    else
      context
    end
  end

  test "info about clean state", %{state: state} do
    assert {:reply, {:ResponseInfo, 'arbitrary information', 'version info', 0, ''}, ^state} = handle_call({:RequestInfo}, nil, state)
  end

  test "checking issue transactions",  %{state: state, alice_info: alice} do

    # correct
    assert {:reply, {:ResponseCheckTx, 0, '', ''}, ^state} =
      handle_call({:RequestCheckTx, "ISSUE asset 5 #{alice.addr}"}, nil, state)

    # malformed
    assert {:reply, {:ResponseCheckTx, 1, '', 'malformed_transaction'}, ^state} =
      handle_call({:RequestCheckTx, "ISSU asset 5 #{alice.addr}"}, nil, state)
    assert {:reply, {:ResponseCheckTx, 1, '', 'malformed_numbers'}, ^state} =
      handle_call({:RequestCheckTx, "ISSUE asset 4.0 #{alice.addr}"}, nil, state)
    assert {:reply, {:ResponseCheckTx, 1, '', 'malformed_numbers'}, ^state} =
      handle_call({:RequestCheckTx, "ISSUE asset 4.1 #{alice.addr}"}, nil, state)
  end

  @tag :alice_has_5
  test "checking send transactions", %{state: state, alice_info: alice, bob_info: bob} do
    
    {:ok, signature} = HonteD.Crypto.sign("0 SEND asset 5 #{alice.addr} #{bob.addr}", alice.priv)
      
    # correct
    assert {:reply, {:ResponseCheckTx, 0, '', ''}, ^state} =
      handle_call({:RequestCheckTx, "0 SEND asset 5 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
      
    # malformed
    assert {:reply, {:ResponseCheckTx, 1, '', 'malformed_transaction'}, ^state} =
      handle_call({:RequestCheckTx, "0 SEN asset 5 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
    assert {:reply, {:ResponseCheckTx, 1, '', 'malformed_numbers'}, ^state} =
      handle_call({:RequestCheckTx, "0 SEND asset 4.0 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
    assert {:reply, {:ResponseCheckTx, 1, '', 'malformed_numbers'}, ^state} =
      handle_call({:RequestCheckTx, "0 SEND asset 4.1 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
  end

  @tag :alice_has_5
  test "querying nonces", %{state: state, alice_info: alice, bob_info: bob} do
    
    {:ok, signature} = HonteD.Crypto.sign("0 SEND asset 5 #{alice.addr} #{bob.addr}", alice.priv)

    assert {:reply, {:ResponseQuery, 0, 0, _key, '0', 'no proof', _, ''}, ^state} =
      handle_call({:RequestQuery, "", '/nonces/#{alice.addr}', 0, false}, nil, state)

    {:reply, _, state} =
      handle_call({:RequestDeliverTx, "0 SEND asset 5 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)

    assert {:reply, {:ResponseQuery, 0, 0, _key, '0', 'no proof', _, ''}, ^state} =
      handle_call({:RequestQuery, "", '/nonces/#{bob.addr}', 0, false}, nil, state)

    assert {:reply, {:ResponseQuery, 0, 0, _key, '1', 'no proof', _, ''}, ^state} =
      handle_call({:RequestQuery, "", '/nonces/#{alice.addr}', 0, false}, nil, state)
  end

  @tag :alice_has_5
  test "checking nonces", %{state: state, alice_info: alice, bob_info: bob} do
    
    {:ok, signature0} = HonteD.Crypto.sign("0 SEND asset 1 #{alice.addr} #{bob.addr}", alice.priv)
    {:ok, signature1} = HonteD.Crypto.sign("1 SEND asset 1 #{alice.addr} #{bob.addr}", alice.priv)
    {:ok, signature2} = HonteD.Crypto.sign("2 SEND asset 1 #{alice.addr} #{bob.addr}", alice.priv)

    assert {:reply, {:ResponseCheckTx, 1, '', 'invalid_nonce'}, ^state} =
      handle_call({:RequestCheckTx, "1 SEND asset 1 #{alice.addr} #{bob.addr} #{signature1}"}, nil, state)
      
    {:reply, _, state} =
      handle_call({:RequestDeliverTx, "0 SEND asset 1 #{alice.addr} #{bob.addr} #{signature0}"}, nil, state)

    assert {:reply, {:ResponseCheckTx, 1, '', 'invalid_nonce'}, ^state} =
      handle_call({:RequestCheckTx, "0 SEND asset 1 #{alice.addr} #{bob.addr} #{signature0}"}, nil, state)
    assert {:reply, {:ResponseCheckTx, 1, '', 'invalid_nonce'}, ^state} =
      handle_call({:RequestCheckTx, "2 SEND asset 1 #{alice.addr} #{bob.addr} #{signature2}"}, nil, state)
    assert {:reply, {:ResponseCheckTx, 0, '', ''}, ^state} =
      handle_call({:RequestCheckTx, "1 SEND asset 1 #{alice.addr} #{bob.addr} #{signature1}"}, nil, state)
  end

  test "hash from commits changes on state update", %{state: state} do
    
    assert {:reply, {:ResponseCommit, 0, cleanhash, _}, ^state} = 
      handle_call({:RequestCommit}, nil, state)
    
    {:reply, _, state} =
      handle_call({:RequestDeliverTx, "ISSUE asset 5 alice"}, nil, state)
      
    assert {:reply, {:ResponseCommit, 0, newhash, _}, ^state} = 
      handle_call({:RequestCommit}, nil, state)
      
    assert newhash != cleanhash
  end
  
  describe "send transactions logic" do
    @tag :alice_has_5
    test "bob has nothing (sanity)", %{state: state, alice_info: alice, bob_info: bob} do
    
      assert {:reply, {:ResponseQuery, 1, 0, _key, '', 'no proof', _, 'not_found'}, ^state} =
        handle_call({:RequestQuery, "", '/accounts/asset/bob', 0, false}, nil, state)
    end
      
    @tag :alice_has_5
    test "correct transfer", %{state: state, alice_info: alice, bob_info: bob} do
      {:ok, signature} = HonteD.Crypto.sign("0 SEND asset 1 #{alice.addr} #{bob.addr}", alice.priv)
      
      assert {:reply, {:ResponseDeliverTx, 0, '', ''}, state} =
        handle_call({:RequestDeliverTx, "0 SEND asset 1 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
      assert {:reply, {:ResponseQuery, 0, 0, _key, '1', 'no proof', _, ''}, ^state} =
        handle_call({:RequestQuery, "", '/accounts/asset/#{bob.addr}', 0, false}, nil, state)
      assert {:reply, {:ResponseQuery, 0, 0, _key, '4', 'no proof', _, ''}, ^state} =
        handle_call({:RequestQuery, "", '/accounts/asset/#{alice.addr}', 0, false}, nil, state)
    end
    
    @tag :alice_has_5
    test "insufficient funds", %{state: state, alice_info: alice, bob_info: bob} do
      {:ok, signature} = HonteD.Crypto.sign("0 SEND asset 6 #{alice.addr} #{bob.addr}", alice.priv)
      
      assert {:reply, {:ResponseCheckTx, 1, '', 'insufficient_funds'}, ^state} =
        handle_call({:RequestCheckTx, "0 SEND asset 6 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
    end
    
    @tag :alice_has_5
    test "negative amount", %{state: state, alice_info: alice, bob_info: bob} do
      {:ok, signature} = HonteD.Crypto.sign("0 SEND asset -1 #{alice.addr} #{bob.addr}", alice.priv)
      
      assert {:reply, {:ResponseCheckTx, 1, '', 'positive_amount_required'}, ^state} =
        handle_call({:RequestCheckTx, "0 SEND asset -1 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
    end
    
    @tag :alice_has_5
    test "zero amount", %{state: state, alice_info: alice, bob_info: bob} do
      {:ok, signature} = HonteD.Crypto.sign("0 SEND asset 0 #{alice.addr} #{bob.addr}", alice.priv)
      
      assert {:reply, {:ResponseCheckTx, 1, '', 'positive_amount_required'}, ^state} =
        handle_call({:RequestCheckTx, "0 SEND asset 0 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
    end      
    
    @tag :alice_has_5
    test "unknown sender", %{state: state, bob_info: bob} do
      assert {:reply, {:ResponseCheckTx, 1, '', 'insufficient_funds'}, ^state} =
        handle_call({:RequestCheckTx, "0 SEND asset 5 carol #{bob.addr} carols_signature"}, nil, state)
    end
    
    @tag :alice_has_5
    test "second consecutive transfer", %{state: state, alice_info: alice, bob_info: bob} do
      
      {:ok, signature} = HonteD.Crypto.sign("0 SEND asset 1 #{alice.addr} #{bob.addr}", alice.priv)
      assert {:reply, _, state} =
        handle_call({:RequestDeliverTx, "0 SEND asset 1 #{alice.addr} #{bob.addr} #{signature}"}, nil, state)
        
      {:ok, signature1_4} = HonteD.Crypto.sign("1 SEND asset 4 #{alice.addr} #{bob.addr}", alice.priv)

      assert {:reply, {:ResponseCheckTx, 0, '', ''}, ^state} =
        handle_call({:RequestCheckTx, "1 SEND asset 4 #{alice.addr} #{bob.addr} #{signature1_4}"}, nil, state)
      assert {:reply, {:ResponseDeliverTx, 0, '', ''}, state} =
        handle_call({:RequestDeliverTx, "1 SEND asset 4 #{alice.addr} #{bob.addr} #{signature1_4}"}, nil, state)
        
      assert {:reply, {:ResponseQuery, 0, 0, _key, '5', 'no proof', _, ''}, ^state} =
        handle_call({:RequestQuery, "", '/accounts/asset/#{bob.addr}', 0, false}, nil, state)
      assert {:reply, {:ResponseQuery, 0, 0, _key, '0', 'no proof', _, ''}, ^state} =
        handle_call({:RequestQuery, "", '/accounts/asset/#{alice.addr}', 0, false}, nil, state)
    end
  end
end
