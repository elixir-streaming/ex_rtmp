defmodule ExRTMP.ServerHandler do
  @moduledoc false

  use ExRTMP.Server.Handler

  alias MediaCodecs.H264
  alias ExFLV.Tag.{AVCVideoPacket, VideoData}
  alias ExRTMP.Server.ClientSession
  alias MediaCodecs.H264.NaluSplitter
  alias MediaCodecs.H264.AccessUnitSplitter

  @dcr <<1, 66, 192, 13, 255, 225, 0, 25, 103, 66, 192, 13, 171, 32, 40, 51, 243, 224, 34, 0, 0,
         3, 0, 2, 0, 0, 3, 0, 97, 30, 40, 84, 144, 1, 0, 4, 104, 206, 60, 128>>

  @impl true
  def init(opts), do: opts

  @impl true
  def handle_play(stream_id, %{name: "test"}, state) do
    pid = self()
    spawn(fn -> send_video(pid, stream_id) end)
    {:ok, state}
  end

  @impl true
  def handle_play(_stream_id, _play, _state) do
    {:error, "Stream not found"}
  end

  defp send_video(pid, stream_id) do
    @dcr
    |> AVCVideoPacket.new(:sequence_header, 0)
    |> VideoData.new(:avc, :keyframe)
    |> ExFLV.Tag.Serializer.serialize()
    |> then(&ClientSession.send_video_data(pid, stream_id, 0, &1))

    "test/fixtures/video.h264"
    |> File.stream!(2048)
    |> parse(:h264)
    |> Enum.reduce(0, fn access_unit, timestamp ->
      keyframe? = Enum.any?(access_unit, &H264.NALU.keyframe?/1)

      access_unit
      |> Enum.map(&[<<byte_size(&1)::32>>, &1])
      |> AVCVideoPacket.new(:nalu, 0)
      |> VideoData.new(:avc, if(keyframe?, do: :keyframe, else: :interframe))
      |> ExFLV.Tag.Serializer.serialize()
      |> then(&ClientSession.send_video_data(pid, stream_id, timestamp, &1))

      timestamp + 50
    end)
  end

  def parse(stream, :h264) do
    stream
    |> Stream.transform(
      fn -> NaluSplitter.new() end,
      &NaluSplitter.process/2,
      &{NaluSplitter.flush(&1), &1},
      &Function.identity/1
    )
    |> Stream.transform(
      fn -> AccessUnitSplitter.new() end,
      fn nalu, splitter ->
        case AccessUnitSplitter.process(nalu, splitter) do
          {nil, splitter} -> {[], splitter}
          {access_unit, splitter} -> {[access_unit], splitter}
        end
      end,
      &{[AccessUnitSplitter.flush(&1)], &1},
      &Function.identity/1
    )
  end
end
