defmodule ExRTMP.Client.MediaProcessor do
  @moduledoc false

  alias ExFLV.Tag.{AudioData, VideoData}
  alias ExRTMP.Message

  @type track :: {:codec, atom(), binary()}
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
    |> VideoData.parse!()
    |> handle_video_tag(message.timestamp, processor)
  end

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
        raise "Expected sequence header as first video tag, got: #{inspect(tag)}"

      processor.video? and packet_type == :sequence_header ->
        raise "Received duplicate video sequence header: #{inspect(tag)}"

      packet_type == :sequence_header ->
        <<_ignore::38, nalu_prefix_size::2, _rest::binary>> = tag.data.data
        processor = %{processor | nalu_prefix_size: nalu_prefix_size + 1}
        {{:codec, :avc, tag.data.data}, %{processor | video?: true}}

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
end
