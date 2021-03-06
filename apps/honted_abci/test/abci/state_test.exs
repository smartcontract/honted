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

defmodule HonteD.ABCI.StateTest do
  @moduledoc """
  This test will pretend to be Tendermint core.

  This test uses `DeliverTx` consistently, but the test-wrapper `deliver_tx` checks parity with `CheckTx` behavior
  """
  # NOTE: we can't enforce this here, because of the keyword-list-y form of create_x calls
  # credo:disable-for-this-file Credo.Check.Refactor.PipeChainStart

  use ExUnitFixtures
  use ExUnit.Case, async: true

  import HonteD.ABCI.TestHelpers

  import HonteD.Transaction
  alias HonteD.Transaction.{Issue, Send, SignOff, Allow, EpochChange}
  alias HonteD.TxCodec

  describe "well formedness of create_token transactions" do
    @tag fixtures: [:issuer, :empty_state]
    test "checking create_token transactions", %{empty_state: state, issuer: issuer} do
      # correct
      create_create_token(nonce: 0, issuer: issuer.addr)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      # malformed
      {<<99>>, 0, issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {<<99>>, 0, "asset", issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)

      # no signature
      {:ok, tx} = create_create_token(nonce: 0, issuer: issuer.addr)
      tx |> encode() |> deliver_tx(state) |> fail?(1, 'missing_signature') |> same?(state)
    end

    @tag fixtures: [:alice, :issuer, :empty_state]
    test "signature checking in create_token", %{empty_state: state, alice: alice, issuer: issuer} do
      create_create_token(nonce: 0, issuer: issuer.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end
  end

  describe "well formedness of issue transactions" do
    @tag fixtures: [:alice, :issuer, :state_with_token, :asset]
    test "checking issue transactions", %{state_with_token: state, alice: alice, issuer: issuer, asset: asset} do
      create_issue(nonce: 1, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      # malformed
      {<<99>>, 1, asset, 5, alice.addr, issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(Issue), 1, asset, 5, 4, alice.addr, issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)

      # no signature
      {:ok, tx} = create_issue(nonce: 1, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr)
      tx |> encode() |> deliver_tx(state) |> fail?(1, 'missing_signature') |> same?(state)
    end

    @tag fixtures: [:alice, :issuer, :state_with_token, :asset]
    test "signature checking in issue", %{state_with_token: state, alice: alice, issuer: issuer, asset: asset} do
      {:ok, tx1} = create_issue(nonce: 1, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr)
      {:ok, tx2} = create_issue(nonce: 1, asset: asset, amount: 4, dest: alice.addr, issuer: issuer.addr)
      fake_sig = misplaced_sign(tx1, tx2, issuer.priv)

      fake_sig |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
      tx1 |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end
  end

  describe "create token and issue transaction logic" do
    @tag fixtures: [:issuer, :alice, :empty_state, :asset]
    test "can't issue not-created token", %{issuer: issuer, alice: alice, empty_state: state, asset: asset} do
      create_issue(nonce: 0, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> fail?(1, 'unknown_issuer') |> same?(state)
    end

    @tag fixtures: [:issuer, :alice, :state_with_token, :asset]
    test "can't issue zero amount", %{state_with_token: state, alice: alice, issuer: issuer, asset: asset} do
      {TxCodec.tx_tag(Issue), 0, asset, 0, alice.addr, issuer.priv}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'positive_amount_required') |> same?(state)
    end

    @tag fixtures: [:empty_state, :asset]
    test "can't find not-created token infos", %{empty_state: state, asset: asset} do
      query(state, '/tokens/#{asset}/issuer') |> not_found?
      query(state, '/tokens/#{asset}/total_supply') |> not_found?
    end

    @tag fixtures: [:state_with_token, :asset]
    test "zero total supply on creation", %{state_with_token: state, asset: asset} do
      query(state, '/tokens/#{asset}/total_supply') |> found?(0)
    end

    @tag fixtures: [:alice, :state_with_token, :asset]
    test "can't issue other issuer's token", %{alice: alice, state_with_token: state, asset: asset} do
      create_issue(nonce: 0, asset: asset, amount: 5, dest: alice.addr, issuer: alice.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'incorrect_issuer') |> same?(state)
    end

    @tag fixtures: [:alice, :issuer, :state_with_token, :asset]
    test "can issue twice", %{alice: alice, issuer: issuer, state_with_token: state, asset: asset} do
      %{state: state} =
        create_issue(nonce: 1, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_issue(nonce: 2, asset: asset, amount: 4, dest: alice.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
      query(state, '/accounts/#{asset}/#{alice.addr}') |> found?(9)
    end

    @tag fixtures: [:issuer, :state_with_token, :asset]
    test "can't unissue unqualified funds", %{issuer: issuer, state_with_token: state, asset: asset} do
      %{state: state} =
        create_issue(nonce: 1, asset: asset, amount: 10, dest: issuer.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv)
        |> deliver_tx(state)
        |> success?

      create_unissue(nonce: 2, asset: asset, amount: 20, issuer: issuer.addr)
      |> encode_sign(issuer.priv)
      |> deliver_tx(state)
      |> same?(state)
    end

    @tag fixtures: [:issuer, :state_with_token, :asset]
    test "can unissue tokens", %{issuer: issuer, state_with_token: state, asset: asset} do
      %{state: state} =
        create_issue(nonce: 1, asset: asset, amount: 10, dest: issuer.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv)
        |> deliver_tx(state)
        |> success?

      %{state: state} =
        create_unissue(nonce: 2, asset: asset, amount: 3, issuer: issuer.addr)
        |> encode_sign(issuer.priv)
        |> deliver_tx(state)
        |> success?

      query(state, '/tokens/#{asset}/total_supply') |> found?(7)
      query(state, '/accounts/#{asset}/#{issuer.addr}') |> found?(7)
    end

    @tag fixtures: [:alice, :state_alice_has_tokens, :asset]
    test "only issuer can unissue tokens", %{alice: alice, state_alice_has_tokens: state, asset: asset} do
     create_unissue(nonce: 1, asset: asset, amount: 3, issuer: alice.addr)
      |> encode_sign(alice.priv)
      |> deliver_tx(state)
      |> fail?(1, 'invalid_nonce')
      |> same?(state)
    end

    @tag fixtures: [:alice, :issuer, :state_with_token, :asset]
    test "signature checking in unissue", %{state_with_token: state, alice: alice, issuer: issuer, asset: asset} do
      {:ok, tx1} = create_unissue(nonce: 1, asset: asset, amount: 5, issuer: issuer.addr)
      {:ok, tx2} = create_unissue(nonce: 1, asset: asset, amount: 4, issuer: issuer.addr)
      fake_sig = misplaced_sign(tx1, tx2, issuer.priv)

      fake_sig |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
      tx1 |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end

    @tag fixtures: [:issuer, :alice, :empty_state]
    test "can create and issue multiple tokens", %{issuer: issuer, alice: alice, empty_state: state} do
      %{state: state} =
        create_create_token(nonce: 0, issuer: issuer.addr) |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_create_token(nonce: 1, issuer: issuer.addr) |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_create_token(nonce: 0, issuer: alice.addr) |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_create_token(nonce: 1, issuer: alice.addr) |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      asset0 = HonteD.Token.create_address(issuer.addr, 0)
      asset1 = HonteD.Token.create_address(issuer.addr, 1)
      asset2 = HonteD.Token.create_address(alice.addr, 0)

      # check that they're different
      assert asset0 != asset1
      assert asset0 != asset2

      # check that they all actually exist and function as intended
      %{state: state} =
        create_issue(nonce: 2, asset: asset0, amount: 5, dest: alice.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_issue(nonce: 2, asset: asset2, amount: 5, dest: alice.addr, issuer: alice.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
      %{state: _} =
        create_issue(nonce: 3, asset: asset1, amount: 5, dest: alice.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
    end

    @tag fixtures: [:issuer, :alice, :state_with_token, :asset]
    test "can't overflow in issue", %{issuer: issuer, alice: alice, state_with_token: state, asset: asset} do
      create_issue(nonce: 1, asset: asset, amount: round(:math.pow(2, 256)), dest: alice.addr, issuer: issuer.addr)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> fail?(1, 'amount_way_too_large') |> same?(state)

      # issue just under the limit to see error in next step
      that_fits = round(:math.pow(2, 256)) - 1
      %{state: state} =
        create_issue(nonce: 1, asset: asset, amount: that_fits, dest: alice.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success? |> commit

      create_issue(nonce: 2, asset: asset, amount: 1, dest: alice.addr, issuer: issuer.addr)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> fail?(1, 'amount_way_too_large') |> same?(state)
    end

    @tag fixtures: [:alice, :empty_state]
    test "can get empty list of issued tokens", %{alice: alice, empty_state: state} do
      query(state, '/issuers/#{alice.addr}') |> not_found?
    end

    @tag fixtures: [:issuer, :alice, :state_with_token, :asset]
    test "can list issued tokens", %{issuer: issuer, alice: alice, state_with_token: state, asset: asset} do
      query(state, '/issuers/#{issuer.addr}') |> found?([asset])
      %{state: state} =
        create_create_token(nonce: 1, issuer: issuer.addr) |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_create_token(nonce: 0, issuer: alice.addr) |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
      asset1 = HonteD.Token.create_address(issuer.addr, 1)
      asset2 = HonteD.Token.create_address(alice.addr, 0)

      query(state, '/issuers/#{issuer.addr}') |> found?([asset1, asset])
      query(state, '/issuers/#{alice.addr}') |> found?([asset2])
    end

    @tag fixtures: [:issuer, :alice, :state_with_token, :asset]
    test "total supply and balance on issue", %{issuer: issuer, alice: alice, state_with_token: state, asset: asset} do
      %{state: state} =
        create_issue(nonce: 1, asset: asset, amount: 5, dest: alice.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      query(state, '/tokens/#{asset}/total_supply') |> found?(5)
      query(state, '/accounts/#{asset}/#{alice.addr}') |> found?(5)

      %{state: state} =
        create_issue(nonce: 2, asset: asset, amount: 7, dest: issuer.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      query(state, '/tokens/#{asset}/total_supply') |> found?(12)
      query(state, '/accounts/#{asset}/#{alice.addr}') |> found?(5)
      query(state, '/accounts/#{asset}/#{issuer.addr}') |> found?(7)
    end

    @tag fixtures: [:issuer, :bob, :empty_state, :asset]
    test "bumping the right nonces in Create/Issue",
    %{empty_state: state, issuer: issuer, bob: bob, asset: asset} do
      %{state: state} =
        create_create_token(nonce: 0, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      query(state, '/nonces/#{issuer.addr}') |> found?(1)

      %{state: state} =
        create_issue(nonce: 1, asset: asset, amount: 5, dest: bob.addr, issuer: issuer.addr)
        |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      query(state, '/nonces/#{bob.addr}') |> found?(0)
      query(state, '/nonces/#{issuer.addr}') |> found?(2)
    end
  end

  describe "well formedness of send transactions" do
    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "checking send transactions", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      # correct
      create_send(nonce: 0, asset: asset, amount: 5, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      # malformed
      {<<99>>, 0, asset, 5, alice.addr, bob.addr}
      |> sign_malformed_tx(alice.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(Send), 0, asset, 5, 4, alice.addr, bob.addr}
      |> sign_malformed_tx(alice.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)

      # no signature
      {:ok, tx} = create_send(nonce: 0, asset: asset, amount: 5, from: alice.addr, to: bob.addr)
      tx |> encode() |> deliver_tx(state) |> fail?(1, 'missing_signature') |> same?(state)
    end
  end

  describe "generic nonce tests" do
    @tag fixtures: [:alice, :empty_state]
    test "querying empty nonces", %{empty_state: state, alice: alice} do
      query(state, '/nonces/#{alice.addr}') |> found?(0)
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "checking nonces", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      create_send(nonce: 1, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)

      %{state: state} =
        create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success? |> commit

      create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
      create_send(nonce: 2, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
      create_send(nonce: 1, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset, :some_block_hash]
    test "nonces common for all transaction types",
    %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset, some_block_hash: hash} do
      %{state: state} =
        create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success? |> commit

      # check transactions other than send
      create_create_token(nonce: 0, issuer: alice.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
      create_issue(nonce: 0, asset: asset, amount: 5, dest: alice.addr, issuer: alice.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
      create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
      create_sign_off(nonce: 0, height: 100, hash: hash, sender: alice.addr, signoffer: alice.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
      create_allow(nonce: 0, allower: alice.addr, allowee: alice.addr, privilege: "signoff", allow: true)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_nonce') |> same?(state)
    end
  end

  describe "send transactions logic" do
    @tag fixtures: [:bob, :state_alice_has_tokens, :asset]
    test "bob has nothing (sanity)", %{state_alice_has_tokens: state, bob: bob, asset: asset} do
      query(state, '/accounts/#{asset}/#{bob.addr}') |> not_found?
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "correct transfer", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      %{state: state} =
        create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
      query(state, '/accounts/#{asset}/#{bob.addr}') |> found?(1)
      query(state, '/accounts/#{asset}/#{alice.addr}') |> found?(4)
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "insufficient funds", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      create_send(nonce: 0, asset: asset, amount: 6, from: alice.addr, to: bob.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'insufficient_funds') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "zero amount", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      {TxCodec.tx_tag(Send), 0, asset, 0, alice.addr, bob.addr}
      |> sign_malformed_tx(alice.priv) |> deliver_tx(state) |> fail?(1, 'positive_amount_required') |> same?(state)
    end

    @tag fixtures: [:bob, :carol, :state_alice_has_tokens, :asset]
    test "unknown sender", %{state_alice_has_tokens: state, bob: bob, carol: carol, asset: asset} do
      create_send(nonce: 0, asset: asset, amount: 1, from: carol.addr, to: bob.addr)
      |> encode_sign(carol.priv) |> deliver_tx(state) |> fail?(1, 'insufficient_funds') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "second consecutive transfer", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      %{state: state} =
        create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
      %{state: state} =
        create_send(nonce: 1, asset: asset, amount: 4, from: alice.addr, to: bob.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      query(state, '/accounts/#{asset}/#{bob.addr}') |> found?(5)
      query(state, '/accounts/#{asset}/#{alice.addr}') |> found?(0)
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "signature checking in send", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      {:ok, tx1} = create_send(nonce: 0, asset: asset, amount: 1, from: alice.addr, to: bob.addr)
      {:ok, tx2} = create_send(nonce: 0, asset: asset, amount: 4, from: alice.addr, to: bob.addr)
      fake_sig = misplaced_sign(tx1, tx2, alice.priv)

      fake_sig |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
      tx1 |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :state_alice_has_tokens, :asset]
    test "bumping the right nonces in Send", %{state_alice_has_tokens: state, alice: alice, bob: bob, asset: asset} do
      %{state: state} =
        create_send(nonce: 0, asset: asset, amount: 5, from: alice.addr, to: bob.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      query(state, '/nonces/#{bob.addr}') |> found?(0)
      query(state, '/nonces/#{alice.addr}') |> found?(1)
    end
  end

  describe "well formedness of sign off transactions" do
    @tag fixtures: [:issuer, :empty_state, :some_block_hash]
    test "checking sign off transactions", %{empty_state: state, issuer: issuer, some_block_hash: hash} do
      create_sign_off(nonce: 0, height: 1, hash: hash, sender: issuer.addr)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      # malformed
      {<<99>>, 0, 1, hash, issuer.addr, issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(SignOff), 0, 1, 2, hash, issuer.addr, issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)

      {TxCodec.tx_tag(SignOff), 0, hash, issuer.addr, issuer.addr}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'missing_signature') |> same?(state)

      # no signature
      {:ok, tx} = create_sign_off(nonce: 0, height: 1, hash: hash, sender: issuer.addr)
      tx |> encode() |> deliver_tx(state) |> fail?(1, 'missing_signature') |> same?(state)
    end

    @tag fixtures: [:alice, :issuer, :empty_state, :some_block_hash]
    test "signature checking in sign off", %{empty_state: state, alice: alice, issuer: issuer, some_block_hash: hash} do
      {:ok, tx1} = create_sign_off(nonce: 0, height: 1, hash: hash, sender: issuer.addr)
      {:ok, tx2} = create_sign_off(nonce: 0, height: 2, hash: hash, sender: issuer.addr)
      fake_sig = misplaced_sign(tx1, tx2, issuer.priv)

      fake_sig |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
      tx1 |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end

  end

  describe "sign off transactions logic," do
    @tag fixtures: [:bob, :empty_state]
    test "initial sign off (sanity)", %{empty_state: state, bob: bob} do
      query(state, '/sign_offs/#{bob.addr}') |> not_found?
    end

    @tag fixtures: [:bob, :empty_state, :some_block_hash]
    test "correct sign_offs", %{empty_state: state, bob: bob, some_block_hash: hash} do
      some_height = 100
      some_next_height = 200

      %{state: state} =
        create_sign_off(nonce: 0, height: some_height, hash: hash, sender: bob.addr)
        |> encode_sign(bob.priv) |> deliver_tx(state) |> success?
      query(state, '/sign_offs/#{bob.addr}') |> found?(%{"height" => some_height, "hash" => hash})

      %{state: state} =
        create_sign_off(nonce: 1, height: some_next_height, hash: String.reverse(hash), sender: bob.addr)
        |> encode_sign(bob.priv) |> deliver_tx(state) |> success?
      query(state, '/sign_offs/#{bob.addr}') |> found?(%{"height" => some_next_height, "hash" => String.reverse(hash)})
    end

    @tag fixtures: [:bob, :empty_state, :some_block_hash]
    test "can't sign_off into the past", %{empty_state: state, bob: bob, some_block_hash: hash} do
      some_height = 100
      some_previous_height = 50
      %{state: state} =
        create_sign_off(nonce: 0, height: some_height, hash: hash, sender: bob.addr)
        |> encode_sign(bob.priv) |> deliver_tx(state) |> success? |> commit

      create_sign_off(nonce: 1, height: some_previous_height, hash: String.reverse(hash), sender: bob.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'sign_off_not_incremental') |> same?(state)
      create_sign_off(nonce: 1, height: some_previous_height, hash: hash, sender: bob.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'sign_off_not_incremental') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :empty_state, :some_block_hash]
    test "can't delegated-signoff unless allowed",
    %{empty_state: state, alice: alice, bob: bob, some_block_hash: hash} do
      create_sign_off(nonce: 0, height: 100, hash: hash, sender: bob.addr, signoffer: alice.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'invalid_delegation') |> same?(state)

      %{state: state} =
        create_allow(nonce: 0, allower: alice.addr, allowee: bob.addr, privilege: "signoff", allow: true)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success? |> commit

      create_sign_off(nonce: 0, height: 100, hash: hash, sender: bob.addr, signoffer: alice.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> success?

      %{state: state} =
        create_allow(nonce: 1, allower: alice.addr, allowee: bob.addr, privilege: "signoff", allow: false)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success? |> commit

      create_sign_off(nonce: 0, height: 100, hash: hash, sender: bob.addr, signoffer: alice.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'invalid_delegation') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :empty_state, :some_block_hash]
    test "sign-off delegation works only one way",
    %{empty_state: state, alice: alice, bob: bob, some_block_hash: hash} do
      %{state: state} =
        create_allow(nonce: 0, allower: bob.addr, allowee: alice.addr, privilege: "signoff", allow: true)
        |> encode_sign(bob.priv) |> deliver_tx(state) |> success? |> commit

      create_sign_off(nonce: 1, height: 100, hash: hash, sender: bob.addr, signoffer: alice.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'invalid_delegation') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :empty_state, :some_block_hash]
    test "encode_sign-off delegation doesn't affect signature checking",
    %{empty_state: state, alice: alice, bob: bob, some_block_hash: hash} do
      %{state: state} =
        create_allow(nonce: 0, allower: alice.addr, allowee: bob.addr, privilege: "signoff", allow: true)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      create_sign_off(nonce: 1, height: 100, hash: hash, sender: alice.addr, signoffer: alice.addr)
      |> encode_sign(bob.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end

    @tag fixtures: [:alice, :empty_state, :some_block_hash]
    test "self sign-off delegation / revoking doesn't change anything",
    %{empty_state: state, alice: alice, some_block_hash: hash} do
      %{state: state} =
        create_allow(nonce: 0, allower: alice.addr, allowee: alice.addr, privilege: "signoff", allow: false)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success? |> commit

      create_sign_off(nonce: 1, height: 100, hash: hash, sender: alice.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      %{state: state} =
        create_allow(nonce: 1, allower: alice.addr, allowee: alice.addr, privilege: "signoff", allow: true)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success? |> commit

      create_sign_off(nonce: 2, height: 100, hash: hash, sender: alice.addr)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> success?
    end

    @tag fixtures: [:bob, :empty_state, :some_block_hash]
    test "zero height", %{empty_state: state, bob: bob, some_block_hash: hash} do
      {TxCodec.tx_tag(SignOff), 0, 0, hash, bob.addr, bob.addr}
      |> sign_malformed_tx(bob.priv) |> deliver_tx(state) |> fail?(1, 'positive_amount_required') |> same?(state)
    end

    @tag fixtures: [:alice, :bob, :empty_state, :some_block_hash]
    test "bumping the right nonces in Allow/Signoff",
    %{empty_state: state, alice: alice, bob: bob, some_block_hash: hash} do
      %{state: state} =
        create_allow(nonce: 0, allower: alice.addr, allowee: bob.addr, privilege: "signoff", allow: true)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      query(state, '/nonces/#{alice.addr}') |> found?(1)

      %{state: state} =
        create_sign_off(nonce: 1, height: 100, hash: hash, sender: alice.addr)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      query(state, '/nonces/#{alice.addr}') |> found?(2)

      %{state: state} =
        create_sign_off(nonce: 0, height: 101, hash: hash, sender: bob.addr, signoffer: alice.addr)
        |> encode_sign(bob.priv) |> deliver_tx(state) |> success?

      query(state, '/nonces/#{bob.addr}') |> found?(1)
      query(state, '/nonces/#{alice.addr}') |> found?(2)
    end
  end

  describe "well formedness of allow transactions," do
    @tag fixtures: [:issuer, :alice, :empty_state]
    test "checking allow transactions", %{empty_state: state, issuer: issuer, alice: alice} do
      create_allow(nonce: 0, allower: issuer.addr, allowee: alice.addr, privilege: "signoff", allow: true)
      |> encode_sign(issuer.priv) |> deliver_tx(state) |> success?

      byte_true = TxCodec.tx_tag(true)

      # malformed
      {<<99>>, 0, issuer.addr, alice.addr, "signoff", byte_true}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(Allow), 0, issuer.addr, alice.addr, "signoff"}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(Allow), 0, issuer.addr, alice.addr, "signoff", byte_true, byte_true}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(Allow), 0, issuer.addr, alice.addr, "signoff", <<99>>}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'malformed_transaction') |> same?(state)
      {TxCodec.tx_tag(Allow), 0, issuer.addr, alice.addr, "signof", byte_true}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'unknown_privilege') |> same?(state)

      # no signature
      {:ok, tx} = create_allow(nonce: 0, allower: issuer.addr, allowee: alice.addr,
                               privilege: "signoff", allow: true)
      tx |> encode() |> deliver_tx(state) |> fail?(1, 'missing_signature') |> same?(state)
    end

    @tag fixtures: [:issuer, :alice, :empty_state]
    test "signature checking in allow", %{empty_state: state, issuer: issuer, alice: alice} do
      {:ok, tx1} = create_allow(nonce: 0, allower: issuer.addr, allowee: alice.addr, privilege: "signoff", allow: false)
      {:ok, tx2} = create_allow(nonce: 0, allower: issuer.addr, allowee: alice.addr, privilege: "signoff", allow: true)
      fake_sig = misplaced_sign(tx1, tx2, issuer.priv)

      fake_sig |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
      tx1 |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_signature') |> same?(state)
    end
  end

  describe "allow transactions logic," do
    @tag fixtures: [:issuer, :alice, :empty_state]
    test "only restricted privileges", %{empty_state: state, issuer: issuer, alice: alice} do
      byte_true = TxCodec.tx_tag(true)
      {TxCodec.tx_tag(Allow), 0, issuer.addr, alice.addr, "signof", byte_true}
      |> sign_malformed_tx(issuer.priv) |> deliver_tx(state) |> fail?(1, 'unknown_privilege') |> same?(state)
    end
  end

  describe "well formedness of epoch change transactions" do
    @tag fixtures: [:alice, :empty_state]
    test "checking epoch change transactions", %{empty_state: state, alice: alice} do
      #correct
      create_epoch_change(nonce: 0, sender: alice.addr, epoch_number: 1)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      #malformed
      {TxCodec.tx_tag(EpochChange), 0, alice.addr, 0}
      |> sign_malformed_tx(alice.priv) |> deliver_tx(state) |> fail?(1, 'positive_amount_required') |> same?(state)
    end
  end

  describe "deliver epoch change transaction," do
    @tag fixtures: [:alice, :empty_state]
    test "apply epoch change transaction", %{empty_state: state, alice: alice} do
      %{state: state} =
        create_epoch_change(nonce: 0, sender: alice.addr, epoch_number: 1)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      query(state, "/contract/epoch_change") |> found?(true)
      query(state, "/contract/epoch_number") |> found?(1)
    end
  end

  describe "check epoch change transaction," do
    @tag fixtures: [:alice, :empty_state]
    test "initialize state with no epoch change and epoch number 0", %{empty_state: state} do
      query(state, "/contract/epoch_change") |> found?(false)
      query(state, "/contract/epoch_number") |> found?(0)
    end

    @tag fixtures: [:alice, :empty_state]
    test "do not apply the same epoch change transaction twice", %{empty_state: state, alice: alice} do
      %{state: state} =
        create_epoch_change(nonce: 0, sender: alice.addr, epoch_number: 1)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      create_epoch_change(nonce: 1, sender: alice.addr, epoch_number: 1)
       |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_epoch_change')
    end

    @tag fixtures: [:alice, :empty_state]
    test "allow for one epoch change transaction in a block", %{empty_state: state, alice: alice} do
      %{state: state} =
        create_epoch_change(nonce: 0, sender: alice.addr, epoch_number: 1)
        |> encode_sign(alice.priv) |> deliver_tx(state) |> success?

      create_epoch_change(nonce: 1, sender: alice.addr, epoch_number: 2)
      |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'invalid_epoch_change')
    end

    @tag fixtures: [:alice, :state_no_epoch_change]
    test "do not apply epoch change when validator block has not passed",
     %{state_no_epoch_change: state, alice: alice} do
       create_epoch_change(nonce: 0, sender: alice.addr, epoch_number: 1)
       |> encode_sign(alice.priv) |> deliver_tx(state) |> fail?(1, 'validator_block_has_not_passed')
       |> same?(state)
    end
  end

end
