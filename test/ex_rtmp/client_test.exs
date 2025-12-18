defmodule ExRTMP.ClientTest do
  use ExUnit.Case, async: true

  alias ExRTMP.Client

  @stream_key "test"

  setup do
    %{server: start_server()}
  end

  describe "start_link/1" do
    test "starts the client", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
      assert is_pid(pid)
      assert Process.alive?(pid)

      assert :ok = Client.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "connect to server" do
    test "connects successfully", %{server: server} do
      assert {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
      assert :ok = Client.connect(pid)

      assert {:ok, stream_id} = Client.create_stream(pid)
      assert is_integer(stream_id)

      assert :ok = Client.delete_stream(pid, stream_id)

      assert :ok = Client.stop(pid)
      refute Process.alive?(pid)
    end

    test "play failed", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: "test2")
      :ok = Client.connect(pid)
      {:ok, stream_id} = Client.create_stream(pid)

      assert {:error, "Stream not found"} = Client.play(pid, stream_id)
    end

    test "stream video data", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
      :ok = Client.connect(pid)
      {:ok, stream_id} = Client.create_stream(pid)
      assert :ok = Client.play(pid, stream_id)

      assert_receive {:video, ^pid, ^stream_id, {:codec, :avc, _data}}
      collected_access_units = collect_received_data([])

      expected_access_units =
        "test/fixtures/video.h264"
        |> File.stream!(1024)
        |> ExRTMP.ServerHandler.parse(:h264)
        |> Enum.to_list()

      assert expected_access_units == collected_access_units

      ExRTMP.Server.stop(server)
      assert_receive {:disconnected, ^pid}, 2000

      Client.stop(pid)
    end
  end

  defp collect_received_data(acc) do
    receive do
      {:video, _pid, _stream_id, {:sample, payload, dts, pts, _keyframe?}} ->
        assert dts == pts
        collect_received_data([payload | acc])
    after
      1000 ->
        Enum.reverse(acc)
    end
  end

  defp start_server do
    start_link_supervised!({ExRTMP.Server, [handler: ExRTMP.ServerHandler, port: 0]})
  end

  defp server_uri(server) do
    {:ok, port} = ExRTMP.Server.port(server)
    "rtmp://localhost:#{port}/live"
  end
end
