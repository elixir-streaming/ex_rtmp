defmodule ExRTMP.ClientTest do
  use ExUnit.Case, async: true

  alias ExFLV.Tag.VideoData
  alias ExRTMP.Client
  alias MediaCodecs.H264

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
      assert :ok = Client.close(pid)

      assert :ok = Client.connect(pid)
      assert {:error, :already_connected} = Client.connect(pid)

      assert :ok = Client.stop(pid)
      refute Process.alive?(pid)
    end

    test "play failed", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: "test2")
      assert {:error, :bad_state} = Client.play(pid)
    end

    test "publish failed", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: "test2")
      assert {:error, :bad_state} = Client.publish(pid)
    end

    test "stream video data", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
      :ok = Client.connect(pid)
      assert :ok = Client.play(pid)

      assert_receive {:video, ^pid, {:codec, :avc, _data}}
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

    test "publish video data", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
      :ok = Client.connect(pid)
      assert :ok = Client.publish(pid)

      expected_access_units =
        "test/fixtures/video.h264"
        |> File.stream!(1024)
        |> ExRTMP.ServerHandler.parse(:h264)
        |> Enum.to_list()

      init_tag =
        ExRTMP.ServerHandler.dcr()
        |> VideoData.AVC.new(:sequence_header, 0)
        |> VideoData.new(:avc, :keyframe)

      Client.send_tag(pid, 0, init_tag)

      Enum.each(expected_access_units, fn access_unit ->
        keyframe? = Enum.any?(access_unit, &H264.NALU.keyframe?/1)

        access_unit
        |> Enum.map(&[<<byte_size(&1)::32>>, &1])
        |> VideoData.AVC.new(:nalu, 0)
        |> VideoData.new(:avc, if(keyframe?, do: :keyframe, else: :interframe))
        |> then(&Client.send_tag(pid, 0, &1))
      end)

      collected_access_units = collect_received_data([])
      assert expected_access_units == collected_access_units

      ExRTMP.Server.stop(server)
      assert_receive {:disconnected, ^pid}, 2000

      Client.stop(pid)
    end
  end

  defp collect_received_data(acc) do
    receive do
      {:video, _pid, {:sample, payload, dts, pts, _keyframe?}} ->
        assert dts == pts
        collect_received_data([payload | acc])
    after
      1000 ->
        Enum.reverse(acc)
    end
  end

  defp start_server do
    start_supervised!(
      {ExRTMP.Server, [handler: ExRTMP.ServerHandler, handler_options: [pid: self()], port: 0]}
    )
  end

  defp server_uri(server) do
    {:ok, port} = ExRTMP.Server.port(server)
    "rtmp://localhost:#{port}/live"
  end
end
