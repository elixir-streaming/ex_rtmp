defmodule ExRTMP.Client.MediaProcessor do
  @moduledoc false

  require Logger
  alias ExFLV.Tag.{AudioData, ExVideoData, VideoData}
  alias ExRTMP.Message

  @compile {:inline, maybe_get_nalus: 2, parse_video_tag: 1}

  @type codec :: :avc | :hvc1 | :aac | :avc1 | :vp08 | :vp09 | :av01 | atom()

  @type track :: {:codec, codec(), binary()}
  @type video_sample ::
          {:sample, payload :: iodata(), dts :: non_neg_integer(), pts :: non_neg_integer(),
           keyframe? :: boolean()}

  @type audio_sample :: {:sample, payload :: iodata(), timestamp :: non_neg_integer()}

  @type video_return :: [track() | video_sample()] | track() | video_sample() | nil
  @type audio_return :: [track() | audio_sample()] | track() | audio_sample() | nil

  @type t :: %__MODULE__{
          video?: boolean(),
          audio?: boolean(),
          nalu_prefix_size: 1..4 | nil
        }

  defstruct [:nalu_prefix_size, video?: false, audio?: false]

  @spec new() :: t()
  def new(), do: %__MODULE__{}

  @spec push_video(Message.t(), t()) :: {video_return(), t()}
  def push_video(message, processor) do
    message.payload
    |> IO.iodata_to_binary()
    |> parse_video_tag()
    |> handle_video_tag(message.timestamp, processor)
  end

  defp parse_video_tag(<<0::1, _::bitstring>> = data), do: VideoData.parse!(data)
  defp parse_video_tag(data), do: ExVideoData.parse!(data)

  @spec push_audio(Message.t(), t()) :: {audio_return(), t()}
  def push_audio(message, processor) do
    message.payload
    |> IO.iodata_to_binary()
    |> AudioData.parse!()
    |> handle_audio_tag(message.timestamp, processor)
  end

  defp handle_video_tag(%VideoData{codec_id: :avc} = tag, timestamp, processor) do
    packet_type = tag.data.packet_type

    cond do
      not processor.video? and packet_type != :sequence_header ->
        Logger.warning("Sequence header not received, dropping")
        {nil, processor}

      packet_type == :sequence_header ->
        processor = %{
          processor
          | nalu_prefix_size: nalu_prefix_size(:avc, tag.data.data),
            video?: true
        }

        {{:codec, :avc, tag.data.data}, processor}

      packet_type == :end_of_sequence ->
        {nil, processor}

      true ->
        payload =
          for <<nalu_size::processor.nalu_prefix_size*8,
                nalu::binary-size(nalu_size) <- tag.data.data>>,
              do: nalu

        sample =
          {:sample, payload, timestamp, timestamp + tag.data.composition_time,
           tag.frame_type == :keyframe}

        {sample, processor}
    end
  end

  defp handle_video_tag(%ExVideoData{} = tag, timestamp, processor) do
    packet_type = tag.packet_type

    cond do
      not processor.video? and packet_type != :sequence_start ->
        Logger.warning("Sequence header not received, dropping")
        {nil, processor}

      packet_type == :sequence_start ->
        processor = %{
          processor
          | nalu_prefix_size: nalu_prefix_size(tag.fourcc, tag.data),
            video?: true
        }

        {{:codec, tag.fourcc, tag.data}, processor}

      packet_type in [:sequence_end, :metadata] ->
        {nil, processor}

      true ->
        pts = timestamp + tag.composition_time_offset
        payload = maybe_get_nalus(processor.nalu_prefix_size, tag.data)
        {{:sample, payload, timestamp, pts, tag.frame_type == :keyframe}, processor}
    end
  end

  defp handle_video_tag(tag, timestamp, %{video?: false} = processor) do
    {[
       {:codec, tag.codec_id, nil},
       {:sample, tag.data, timestamp, timestamp, tag.frame_type == :keyframe}
     ], %{processor | video?: true}}
  end

  defp handle_video_tag(tag, timestamp, processor) do
    sample = {:sample, tag.data, timestamp, timestamp, tag.frame_type == :keyframe}
    {sample, processor}
  end

  defp handle_audio_tag(%AudioData{sound_format: :aac} = tag, timestamp, processor) do
    case tag.data.packet_type do
      :sequence_header ->
        {{:codec, :aac, tag.data.data}, processor}

      :raw ->
        {{:sample, tag.data.data, timestamp}, processor}
    end
  end

  defp handle_audio_tag(%AudioData{} = tag, timestamp, %{audio?: false} = processor) do
    {[{:codec, tag.sound_format, nil}, {:sample, tag.data, timestamp}],
     %{processor | audio?: true}}
  end

  defp handle_audio_tag(%AudioData{} = tag, timestamp, processor) do
    {{:sample, tag.data, timestamp}, processor}
  end

  defp nalu_prefix_size(:hvc1, <<_::binary-size(21), _::6, nalu_prefix_size::2, _::binary>>) do
    nalu_prefix_size + 1
  end

  defp nalu_prefix_size(codec, <<_::38, nalu_prefix_size::2, _::binary>>)
       when codec == :avc or codec == :avc1 do
    nalu_prefix_size + 1
  end

  defp nalu_prefix_size(_, _), do: nil

  defp maybe_get_nalus(nil, data), do: data

  defp maybe_get_nalus(nalu_prefix_size, data) do
    for <<nalu_size::nalu_prefix_size*8, nalu::binary-size(nalu_size) <- data>>, do: nalu
  end
end
