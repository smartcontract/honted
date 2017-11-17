defmodule HonteD.API.EventsTest do
  @moduledoc """
  Tests how one can use the API to subscribe to topics and receive event notifications

  Uses the application's instance of HonteD.Events.Eventer

  Uses the public HonteD.API for subscription/unsubscription and the public HonteD.Events api to emit events
  
  We test the logic of the events here
  """

  import HonteD.API.TestHelpers

  import HonteD.Events

  use ExUnitFixtures
  use ExUnit.Case, async: true

  @timeout 100

  ## helpers

  deffixture server do
    {:ok, pid} = GenServer.start(HonteD.Events.Eventer, [], [])
    pid
  end

  ## tests

  describe "Tests infrastructure sanity: server and test clients start and stop." do
    test "Assert_receive/2 is selective receive." do
      msg1 = :stop1
      msg2 = :stop2
      pid = client(fn() ->
        assert_receive(^msg2, @timeout)
        assert_receive(^msg1, @timeout)
      end)
      send(pid, msg1)
      send(pid, msg2)
      join()
    end
  end

  describe "One can register for events and receive it." do
    @tag fixtures: [:server]
    test "Subscribe, send event, receive event.", %{server: server}  do
      {e1, receivable1} = event_send(address1())
      pid = client(fn() -> assert_receive(^receivable1, @timeout) end)
      :ok = new_send_filter(server, pid, address1())
      notify(server, e1, [])
      join()
    end

    @tag fixtures: [:server]
    test "empty subscriptions still work", %{server: server} do
      {e1, _} = event_send(address1())
      _ = client(fn() -> refute_receive(_, @timeout) end)
      notify(server, e1, [])
      join()
    end

    @tag fixtures: [:server]
    test "multiple subscriptions work once", %{server: server} do
      {e1, receivable1} = event_send(address1())
      pid = client(fn() ->
        assert_receive(^receivable1, @timeout)
        refute_receive(_, @timeout)
      end)
      new_send_filter(server, pid, address1())
      new_send_filter(server, pid, address1())
      new_send_filter(server, pid, address1())
      notify(server, e1, [])
      join()
    end
  end

  describe "Both :committed and :finalized events are delivered." do
    @tag fixtures: [:server]
    test "Only :committed is delivered if sign_off is not issued.", %{server: server} do
      {e1, receivable} = event_send(address1())
      pid = client(fn() ->
        assert_receive(^receivable, @timeout)
        refute_receive(_, @timeout)
      end)
      new_send_filter(server, pid, address1())
      notify(server, e1, [])
      join()
    end

    @tag fixtures: [:server]
    test "Both are delivered if sign_off is issued.", %{server: server} do
      {e1, com1} = event_send(address1(), "asset1")
      {e2, com2} = event_send(address1(), "asset2")
      {e3, com3} = event_send(address1(), "asset1")
      {s1, [fin1, fin2, fin3]} = event_sign_off(address1(), [com1, com2, com3])
      pid = client(fn() ->
        assert_receive(^com1, @timeout)
        assert_receive(^com2, @timeout)
        assert_receive(^com3, @timeout)
        assert_receive(^fin1, @timeout)
        assert_receive(^fin2, @timeout)
        assert_receive(^fin3, @timeout)
      end)
      new_send_filter(server, pid, address1())
      notify(server, e1, [])
      notify(server, e2, [])
      notify(server, e3, [])
      notify(server, s1, ["asset1", "asset2"])
      join()
    end
    
    @tag fixtures: [:server]
    test "Sign_off delivers tokens of the issuer who did the sign off", %{server: server} do
      {e1, com1} = event_send(address1(), "asset1")
      {e2, com2} = event_send(address1(), "asset2")
      {e3, com3} = event_send(address1(), "asset3")
      {s1, [fin1, fin2]} = event_sign_off(address2(), [com1, com2])
      
      pid = client(fn() ->
        assert_receive(^com1, @timeout)
        assert_receive(^com2, @timeout)
        assert_receive(^com3, @timeout)
        assert_receive(^fin1, @timeout)
        assert_receive(^fin2, @timeout)
        refute_receive(_, @timeout)
      end)
      new_send_filter(server, pid, address1())
      notify(server, e1, [])
      notify(server, e2, [])
      notify(server, e3, [])
      notify(server, s1, ["asset1", "asset2"])
      join()
    end

    @tag fixtures: [:server]
    test "Sign_off finalizes transactions only to certain height", %{server: server} do
      {e1, com1} = event_send(address1(), "asset")
      {e2, com2} = event_send(address1(), "asset")
      {f1, [fin1, fin2]} = event_sign_off(address1(), [com1, com2], 1)
      pid = client(fn() ->
        assert_receive(^fin1, @timeout)
        refute_receive(^fin2, @timeout)
      end)
      new_send_filter(server, pid, address1())
      notify(server, %HonteD.Events.NewBlock{height: 1}, [])
      notify(server, e1, [])
      notify(server, %HonteD.Events.NewBlock{height: 2}, [])
      notify(server, e2, [])
      notify(server, f1, ["asset"])
      join()
    end

    @tag fixtures: [:server]
    test "Sign_off can be continued at later height", %{server: server} do
      {e1, com1} = event_send(address1(), "asset")
      {e2, com2} = event_send(address1(), "asset")
      {f1, [fin1]} = event_sign_off(address1(), [com1], 1)
      {f2, [fin2]} = event_sign_off(address1(), [com2], 2)
      pid = client(fn() ->
        assert_receive(^fin1, @timeout)
        assert_receive(^fin2, @timeout)
      end)
      new_send_filter(server, pid, address1())
      notify(server, %HonteD.Events.NewBlock{height: 1}, [])
      notify(server, e1, [])
      notify(server, %HonteD.Events.NewBlock{height: 2}, [])
      notify(server, e2, [])
      notify(server, f1, ["asset"])
      notify(server, f2, ["asset"])
      join()
    end
  end

  describe "Subscribes and unsubscribes are handled." do
    @tag fixtures: [:server]
    test "Manual unsubscribe.", %{server: server} do
      pid = client(fn() -> refute_receive(_, @timeout) end)
      assert {:ok, false} = status_send_filter?(server, pid, address1())
      new_send_filter(server, pid, address1())
      assert {:ok, true} = status_send_filter?(server, pid, address1())
      :ok = drop_send_filter(server, pid, address1())
      assert {:ok, false} = status_send_filter?(server, pid, address1())

      # won't be notified
      {e1, _} = event_send(address1())
      notify(server, e1, [])
      join()
    end

    @tag fixtures: [:server]
    test "Automatic unsubscribe/cleanup.", %{server: server} do
      {e1, receivable1} = event_send(address1())
      pid1 = client(fn() -> assert_receive(^receivable1, @timeout) end)
      pid2 = client(fn() ->
        assert_receive(^receivable1, @timeout)
        assert_receive(^receivable1, @timeout)
      end)
      new_send_filter(server, pid1, address1())
      new_send_filter(server, pid2, address1())
      assert {:ok, true} = status_send_filter?(server, pid1, address1())
      notify(server, e1, [])
      join(pid1)
      assert {:ok, false} = status_send_filter?(server, pid1, address1())
      assert {:ok, true} = status_send_filter?(server, pid2, address1())
      notify(server, e1, [])
      join()
    end
  end

  describe "Topics are handled." do
    @tag fixtures: [:server]
    test "Topics are distinct.", %{server: server} do
      {e1, receivable1} = event_send(address1())
      pid1 = client(fn() -> assert_receive(^receivable1, @timeout) end)
      pid2 = client(fn() -> refute_receive(^receivable1, @timeout) end)
      new_send_filter(server, pid1, address1())
      new_send_filter(server, pid2, address2())
      notify(server, e1, [])
      join()
    end

    @tag fixtures: [:server]
    test "Similar send transactions don't match, but get accepted by Eventer.", %{server: server} do
      # NOTE: behavior will require rethinking
      unhandled_e = %HonteD.Transaction.Issue{nonce: 0, asset: "asset", amount: 1,
                                              dest: address1(), issuer: "issuer_addr"}
      pid1 = client(fn() -> refute_receive(_, @timeout) end)
      new_send_filter(server, pid1, address1())
      notify(server, unhandled_e, [])
      join()
    end

    @tag fixtures: [:server]
    test "Outgoing send transaction don't match.", %{server: server} do
      # NOTE: behavior will require rethinking
      e1 = %HonteD.Transaction.Send{nonce: 0, asset: "asset", amount: 1,
                                    from: address1(), to: "to_addr"}
      pid1 = client(fn() -> refute_receive(_, @timeout) end)
      new_send_filter(server, pid1, address1())
      notify(server, e1, [])
      join()
    end
  end

  describe "API does sanity checks on arguments." do
    @tag fixtures: [:server]
    test "Good topic.", %{server: server} do
      assert :ok = new_send_filter(server, self(), address1())
    end
    test "Bad topic." do
      assert {:error, _} = new_send_filter(self(), 'this is not a binary')
    end
    @tag fixtures: [:server]
    test "Good sub.", %{server: server} do
      assert :ok = new_send_filter(server, self(), address1())
    end
    test "Bad sub." do
      assert {:error, _} = new_send_filter(:registered_processes_will_not_be_handled,
                                           address1())
    end
  end

end
