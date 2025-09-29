defmodule ExRTMP.Client.MediaProcessor do
  @moduledoc false

  alias ExFLV.Tag.VideoData

  @type t :: %__MODULE__{
          last_video_sample: {non_neg_integer(), VideoData.t()} | nil,
          nalu_prefix_size: 1..4 | nil
        }

  defstruct [:last_video_sample, :nalu_prefix_size]

  @spec new() :: t()
  def new(), do: %__MODULE__{}

  @spec push_video(t(), non_neg_integer(), iodata()) :: {tuple() | nil, t()}
  def push_video(processor, timestamp, data) do
    data
    |> IO.iodata_to_binary()
    |> VideoData.parse()
    |> handle_video_tag(timestamp, processor)
  end

  defp handle_video_tag(%VideoData{codec_id: :avc} = tag, timestamp, processor) do
    {last_timestamp, tags} = last_sample(processor.last_video_sample)
    packet_type = tag.data.packet_type

    cond do
      is_nil(last_timestamp) and packet_type != :sequence_header ->
        raise "Expected sequence header as first video tag, got: #{inspect(tag)}"

      packet_type == :sequence_header ->
        <<_ignore::38, nalu_prefix_size::2, _rest::binary>> = tag.data.data

        processor = %{
          processor
          | nalu_prefix_size: nalu_prefix_size + 1,
            last_video_sample: {timestamp, []}
        }

        {{:codec, tag.codec_id, tag.data.data}, processor}

      is_nil(last_timestamp) or last_timestamp == timestamp ->
        {nil, %{processor | last_video_sample: {timestamp, [tag | tags]}}}

      true ->
        first_tag = hd(tags)

        sample =
          {:sample, get_avc_payload(tags, processor.nalu_prefix_size), last_timestamp,
           last_timestamp + first_tag.data.composition_time, first_tag.frame_type == :keyframe}

        processor =
          if packet_type != :end_of_sequence,
            do: %{processor | last_video_sample: {timestamp, [tag]}},
            else: processor

        {sample, processor}
    end
  end

  defp handle_video_tag(tag, timestamp, processor) do
    {last_timestamp, tags} = last_sample(processor.last_video_sample)

    cond do
      is_nil(last_timestamp) ->
        processor = %{processor | last_video_sample: {timestamp, [tag]}}
        {{:codec, tag.codec_id, nil}, processor}

      last_timestamp == timestamp ->
        {nil, %{processor | last_video_sample: {timestamp, [tag | tags]}}}

      true ->
        sample_data = tags |> Stream.map(& &1.data) |> Enum.reverse()

        sample =
          {:sample, sample_data, last_timestamp, last_timestamp, hd(tags).frame_type == :keyframe}

        processor = %{processor | last_video_sample: {timestamp, [tag]}}
        {sample, processor}
    end
  end

  defp last_sample(nil), do: {nil, []}
  defp last_sample(last_sample), do: last_sample

  defp get_avc_payload(tags, nalu_prefix_size) do
    sample_data =
      tags
      |> Stream.map(& &1.data.data)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    for <<nalu_size::nalu_prefix_size*8, nalu::binary-size(nalu_size) <- sample_data>>,
      do: nalu
  end
end
