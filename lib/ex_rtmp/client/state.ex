defmodule ExRTMP.Client.State do
  @moduledoc false

  alias ExRTMP.ChunkParser
  alias ExRTMP.Client.MediaProcessor
  alias ExRTMP.Message

  @default_window_ack_size 2_500_000

  @type command :: :connect | :create_stream | :play | :publish
  @type state :: :init | :connected | :playing | :publishing

  @type t :: %__MODULE__{
          uri: URI.t(),
          stream_key: String.t(),
          socket: port() | nil,
          chunk_parser: ChunkParser.t(),
          receiver: pid(),
          pending_peer: GenServer.from() | nil,
          pending_action: command() | nil,
          next_ts_id: non_neg_integer(),
          window_ack_size: non_neg_integer(),
          stream_id: Message.stream_id() | nil,
          state: state(),
          media_processor: MediaProcessor.t() | nil
        }

  @enforce_keys [:uri, :stream_key]
  defstruct @enforce_keys ++
              [
                :socket,
                :pending_peer,
                :pending_action,
                :receiver,
                :stream_id,
                :media_processor,
                state: :init,
                chunk_parser: ChunkParser.new(),
                next_ts_id: 2,
                window_ack_size: @default_window_ack_size
              ]

  @doc false
  @spec handle_media_message(t(), ExRTMP.Message.t()) ::
          {ExRTMP.Client.MediaProcessor.video_return(), t()}
  def handle_media_message(state, %{type: 8} = message) do
    {data, processor} = MediaProcessor.push_audio(message, state.media_processor)
    {data, %{state | media_processor: processor}}
  end

  def handle_media_message(state, %{type: 9} = message) do
    {data, processor} = MediaProcessor.push_video(message, state.media_processor)
    {data, %{state | media_processor: processor}}
  end

  @doc false
  @spec reset(t()) :: t()
  def reset(state) do
    %__MODULE__{uri: state.uri, stream_key: state.stream_key, receiver: state.receiver}
  end
end
