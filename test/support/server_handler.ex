defmodule ExRTMP.ServerHandler do
  @moduledoc false

  use ExRTMP.Server.Handler

  alias ExFLV.Tag.{AudioData, ExVideoData, Serializer, VideoData, VideoData.AVC}
  alias ExRTMP.Server.ClientSession
  alias MediaCodecs.H264
  alias MediaCodecs.H264.AccessUnitSplitter
  alias MediaCodecs.H264.NaluSplitter
  alias MediaCodecs.H265.AccessUnitSplitter, as: HevcAccessUnitSplitter
  alias MediaCodecs.H265.NaluSplitter, as: HevcNaluSplitter

  @dcr <<1, 66, 192, 13, 255, 225, 0, 25, 103, 66, 192, 13, 171, 32, 40, 51, 243, 224, 34, 0, 0,
         3, 0, 2, 0, 0, 3, 0, 97, 30, 40, 84, 144, 1, 0, 4, 104, 206, 60, 128>>

  @hevc_dcr <<1, 1, 96, 0, 0, 0, 144, 0, 0, 0, 0, 0, 60, 240, 0, 252, 253, 248, 248, 0, 0, 7, 3,
              160, 0, 1, 0, 24, 64, 1, 12, 1, 255, 255, 1, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3,
              0, 60, 149, 152, 9, 161, 0, 1, 0, 43, 66, 1, 1, 1, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0,
              0, 3, 0, 60, 160, 10, 8, 11, 159, 121, 101, 102, 146, 76, 175, 1, 104, 8, 0, 0, 3,
              0, 8, 0, 0, 3, 0, 192, 64, 162, 0, 1, 0, 7, 68, 1, 193, 114, 180, 98, 64>>

  def dcr, do: @dcr

  @impl true
  def handle_play(%{name: "test"}, state) do
    pid = self()
    spawn(fn -> send_media(pid, state[:fixture]) end)
    {:ok, state}
  end

  @impl true
  def handle_play(_play, _state) do
    {:error, "Stream not found"}
  end

  @impl true
  def handle_video_data(_, sample, state) do
    send(state[:pid], {:video, self(), sample})
    state
  end

  defp send_media(pid, fixture) do
    {codec, stream} = parse(fixture)

    init_tag =
      case codec do
        :h264 -> h264_dcr_tag(@dcr)
        :hevc -> hevc_dcr_tag(@hevc_dcr)
        :pcma -> nil
      end

    if init_tag do
      send_data(pid, 0, init_tag)
    end

    Enum.reduce(stream, 0, fn access_unit, timestamp ->
      codec
      |> create_tag(access_unit)
      |> then(&send_data(pid, timestamp, &1))

      timestamp + 50
    end)
  end

  def parse(fixture) do
    codec =
      case Path.extname(fixture) do
        ".h264" -> :h264
        ".hevc" -> :hevc
        ".pcma" -> :pcma
      end

    stream =
      fixture
      |> File.stream!(2048)
      |> parse(codec)

    {codec, stream}
  end

  def parse(stream, :h264) do
    parse_h26x(stream, NaluSplitter, AccessUnitSplitter)
  end

  def parse(stream, :hevc) do
    parse_h26x(stream, HevcNaluSplitter, HevcAccessUnitSplitter)
  end

  def parse(stream, :pcma), do: stream

  defp parse_h26x(stream, splitter_mod, au_splitter_mod) do
    stream
    |> Stream.transform(
      fn -> splitter_mod.new() end,
      &splitter_mod.process/2,
      &{splitter_mod.flush(&1), &1},
      &Function.identity/1
    )
    |> Stream.transform(
      fn -> au_splitter_mod.new() end,
      fn nalu, splitter ->
        case au_splitter_mod.process(nalu, splitter) do
          {nil, splitter} -> {[], splitter}
          {access_unit, splitter} -> {[access_unit], splitter}
        end
      end,
      &{[au_splitter_mod.flush(&1)], &1},
      &Function.identity/1
    )
  end

  defp h264_dcr_tag(dcr) do
    dcr
    |> AVC.new(:sequence_header, 0)
    |> VideoData.new(:h264, :keyframe)
  end

  defp hevc_dcr_tag(dcr) do
    %ExVideoData{
      frame_type: :keyframe,
      packet_type: :sequence_start,
      codec_id: :h265,
      data: dcr
    }
  end

  defp create_tag(:h264, access_unit) do
    access_unit
    |> Enum.map(&[<<byte_size(&1)::32>>, &1])
    |> AVC.new(:nalu, 0)
    |> VideoData.new(
      :h264,
      if(Enum.any?(access_unit, &H264.NALU.keyframe?/1), do: :keyframe, else: :interframe)
    )
  end

  defp create_tag(:hevc, access_unit) do
    payload = Enum.map(access_unit, &[<<byte_size(&1)::32>>, &1])
    keyframe? = Enum.any?(access_unit, &MediaCodecs.H265.NALU.keyframe?/1)

    %ExVideoData{
      frame_type: if(keyframe?, do: :keyframe, else: :interframe),
      packet_type: :coded_frames,
      codec_id: :h265,
      data: payload
    }
  end

  defp create_tag(:pcma, data) do
    %AudioData{
      sound_format: :pcma,
      sound_size: 0,
      sound_rate: 1,
      sound_type: :mono,
      data: data
    }
  end

  defp send_data(pid, timestamp, %AudioData{} = data) do
    ClientSession.send_audio_data(pid, timestamp, Serializer.serialize(data))
  end

  defp send_data(pid, timestamp, data) do
    ClientSession.send_video_data(pid, timestamp, Serializer.serialize(data))
  end
end
