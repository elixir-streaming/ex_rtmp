defmodule ExRTMP.Client.StreamContext do
  @moduledoc false

  alias ExRTMP.Client.MediaProcessor

  @type state :: :created | :playing | :publishing
  @type action :: :play | :publish | :delete

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          state: state(),
          pending_action: action() | nil,
          pending_peer: GenServer.from() | nil
        }

  defstruct [
    :id,
    :pending_action,
    :pending_peer,
    state: :created,
    media_processor: MediaProcessor.new()
  ]

  @doc false
  @spec handle_video_data(t(), ExRTMP.Message.t()) :: {MediaProcessor.video_return(), t()}
  def handle_video_data(stream_ctx, message) do
    {data, processor} =
      MediaProcessor.push_video(stream_ctx.media_processor, message.timestamp, message.payload)

    stream_ctx = %{stream_ctx | media_processor: processor}
    {data, stream_ctx}
  end

  @doc false
  @spec handle_audio_data(t(), ExRTMP.Message.t()) :: {MediaProcessor.audio_return(), t()}
  def handle_audio_data(stream_ctx, message) do
    {data, processor} =
      MediaProcessor.push_audio(stream_ctx.media_processor, message.timestamp, message.payload)

    stream_ctx = %{stream_ctx | media_processor: processor}
    {data, stream_ctx}
  end
end
