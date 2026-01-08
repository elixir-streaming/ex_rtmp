defmodule ExRTMP.ClientTest do
  use ExUnit.Case, async: true

  alias ExFLV.Tag.VideoData
  alias ExRTMP.Client
  alias MediaCodecs.H264

  @stream_key "test"

  setup do
    %{server: start_server(nil)}
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

    for {fixture, codec} <- [
          {"test/fixtures/video.h264", :h264},
          {"test/fixtures/video.hevc", :hevc},
          {"test/fixtures/audio.pcma", :pcma}
        ] do
      test "stream video data: #{codec}" do
        server = start_server(unquote(fixture))

        {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
        :ok = Client.connect(pid)
        assert :ok = Client.play(pid)

        assert_receive {media_type, ^pid, {:codec, received_codec, _data}}

        case unquote(codec) do
          :h264 ->
            assert media_type == :video
            assert received_codec == :avc

          :hevc ->
            assert media_type == :video
            assert received_codec == :hvc1

          :pcma ->
            assert media_type == :audio
            assert received_codec == :g711_alaw
        end

        collected_access_units = collect_received_data([])

        expected_access_units =
          unquote(fixture)
          |> ExRTMP.ServerHandler.parse()
          |> elem(1)
          |> Enum.to_list()

        assert length(expected_access_units) == length(collected_access_units)
        assert expected_access_units == collected_access_units

        ExRTMP.Server.stop(server)
        assert_receive {:disconnected, ^pid}, 2000

        Client.stop(pid)
      end
    end

    test "publish video data", %{server: server} do
      {:ok, pid} = Client.start_link(uri: server_uri(server), stream_key: @stream_key)
      :ok = Client.connect(pid)
      assert :ok = Client.publish(pid)

      expected_access_units =
        ExRTMP.ServerHandler.parse("test/fixtures/video.h264")
        |> elem(1)
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

      {:audio, _pid, {:sample, payload, _pts}} ->
        collect_received_data([payload | acc])
    after
      1000 ->
        Enum.reverse(acc)
    end
  end

  defp start_server(fixture) do
    {:ok, pid} =
      ExRTMP.Server.start(
        handler: ExRTMP.ServerHandler,
        handler_options: [pid: self(), fixture: fixture],
        port: 0
      )

    pid
  end

  defp server_uri(server) do
    {:ok, port} = ExRTMP.Server.port(server)
    "rtmp://localhost:#{port}/live"
  end
end
