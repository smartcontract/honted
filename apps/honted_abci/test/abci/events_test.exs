defmodule HonteD.ABCI.EventsTest do
  @moduledoc """
  Tests if Events are processed correctly, by the registered :honted_events app

  THis tests only the integration between ABCI and the Eventer GenServer, i.e. whether the events are emitted
  correctly. No HonteD.API.Events logic tested here
  """
  use ExUnitFixtures
  use ExUnit.Case, async: false  # modifies the ABCI's registered Eventer process

  import HonteD.API.TestHelpers
  import HonteD.ABCI.TestHelpers

  @test_eventer HonteD.API.Events.Eventer
  @timeout 100

  deffixture server_spawner() do
    # returns a function that spawns a process waiting for a particular expected message (or silence)
    # this is used to mock the Eventer GenServer
    # this process is registered in lieu of the Eventer, and should be `join`ed at the end of test
    # NOTE: consider using `Mox` to simulate receiving server. Reason: consistency
    fn expected_case ->
      # the following case determines the expected behavior of the spawned process
      server_pid = case expected_case do
        :expected_silence ->
          spawn_link(fn ->
            refute_receive(_, @timeout)
          end)
        expected_predicate when is_function(expected_predicate) ->
          spawn_link(fn ->
            received_cast = receive do
              {:"$gen_cast", received_message} -> received_message
            after
              @timeout -> assert false
            end

            received_cast
            |> expected_predicate.()
            |> assert
          end)
      end
      # plug the proces where the Eventer Genserver is expected
      Process.register(server_pid, @test_eventer)
      server_pid
    end
  end

  describe "ABCI and Eventer work together." do
    @tag fixtures: [:server_spawner, :empty_state, :issuer]
    test "create token transaction emits events", %{empty_state: state, issuer: issuer, server_spawner: server_spawner} do
      params = [nonce: 0, issuer: issuer.addr]
      server_pid = server_spawner.(
        fn {:event, %HonteD.Transaction.SignedTx{raw_tx: raw_tx}} ->
          {:ok, tx} = create_create_token(params)
          raw_tx == tx
        end
      )

      params |> create_create_token |> encode_sign(issuer.priv) |> deliver_tx(state)
      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :state_with_token, :alice, :asset, :issuer]
    test "issue transaction emits events", %{state_with_token: state, asset: asset, alice: alice, issuer: issuer,
                                             server_spawner: server_spawner} do
      params = [nonce: 1, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr]
      server_pid = server_spawner.(
        fn {:event, %HonteD.Transaction.SignedTx{raw_tx: raw_tx}} ->
          {:ok, tx} = create_issue(params)
          raw_tx == tx
        end
      )

      params |> create_issue |> encode_sign(issuer.priv) |> deliver_tx(state)
      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :state_alice_has_tokens, :alice, :bob, :asset]
    test "send transaction emits events", %{state_alice_has_tokens: state, asset: asset, alice: alice, bob: bob,
                                            server_spawner: server_spawner} do
      params = [nonce: 0, asset: asset, amount: 5, from: alice.addr, to: bob.addr]
      server_pid = server_spawner.(
        fn {:event, %HonteD.Transaction.SignedTx{raw_tx: raw_tx}} ->
          {:ok, tx} = create_send(params)
          raw_tx == tx
        end
      )

      params |> create_send |> encode_sign(alice.priv) |> deliver_tx(state)
      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :state_with_token, :some_block_hash, :issuer, :alice, :asset]
    test "signoff transaction emits events with tokens", %{state_with_token: state, issuer: issuer, alice: alice,
                                                           some_block_hash: hash, server_spawner: server_spawner,
                                                           asset: asset} do
      setup_params = [nonce: 1, allower: issuer.addr, allowee: alice.addr, privilege: "signoff", allow: true]
      %{state: state} =
        setup_params |> create_allow |> encode_sign(issuer.priv) |> deliver_tx(state)

      params = [nonce: 0, height: 1, hash: hash, sender: alice.addr, signoffer: issuer.addr]
      raw_asset = asset |> HonteD.Crypto.hex_to_address!()
      server_pid = server_spawner.(
        fn {:event_context, %HonteD.Transaction.SignedTx{raw_tx: raw_tx}, [^raw_asset]} ->
          {:ok, expected} = create_sign_off(params)
          raw_tx == expected
        end
      )

      params |> create_sign_off |> encode_sign(alice.priv) |> deliver_tx(state)
      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :empty_state, :issuer, :alice]
    test "allow transaction emits events", %{empty_state: state, issuer: issuer, alice: alice,
                                             server_spawner: server_spawner} do
      params = [nonce: 0, allower: issuer.addr, allowee: alice.addr, privilege: "signoff", allow: true]
      server_pid = server_spawner.(
        fn {:event, %HonteD.Transaction.SignedTx{raw_tx: raw_tx}} ->
          {:ok, tx} = create_allow(params)
          raw_tx == tx
        end
      )

      params |> create_allow |> encode_sign(issuer.priv) |> deliver_tx(state)
      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :empty_state, :some_block_hash, :issuer]
    test "correct tx doesn't emit on check tx", %{empty_state: state, issuer: issuer, some_block_hash: hash,
                                                  server_spawner: server_spawner} do
      params = [nonce: 0, height: 1, hash: hash, sender: issuer.addr]
      server_pid = server_spawner.(:expected_silence)

      params |> create_sign_off |> encode_sign(issuer.priv) |> check_tx(state)
      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :empty_state, :some_block_hash, :issuer]
    test "statefully incorrect tx doesn't emit", %{empty_state: state, issuer: issuer, some_block_hash: hash,
                                                   server_spawner: server_spawner} do
      params = [nonce: 1, height: 1, hash: hash, sender: issuer.addr]
      server_pid = server_spawner.(:expected_silence)

      params |> create_sign_off |> encode_sign(issuer.priv) |> deliver_tx(state)

      join(server_pid)
    end

    @tag fixtures: [:server_spawner, :empty_state, :some_block_hash, :issuer, :alice]
    test "statelessly incorrect tx doesn't emit", %{empty_state: state, issuer: issuer, alice: alice,
                                                    some_block_hash: hash,
                                                    server_spawner: server_spawner} do
      params = [nonce: 0, height: 1, hash: hash, sender: issuer.addr]
      server_pid = server_spawner.(:expected_silence)

      params |> create_sign_off |> encode_sign(alice.priv) |> deliver_tx(state)

      join(server_pid)
    end

  end
end
