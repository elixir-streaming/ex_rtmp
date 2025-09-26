defmodule ExRTMP.Client.State do
  @moduledoc false

  alias ExRTMP.ChunkParser
  alias ExRTMP.Client.StreamContext
  alias ExRTMP.Message

  @default_window_ack_size 2_500_000

  @type command :: :connect | :create_stream | :play

  @type t :: %__MODULE__{
          uri: URI.t(),
          stream_key: String.t(),
          socket: port() | nil,
          chunk_parser: ChunkParser.t(),
          pending_peer: GenServer.from() | nil,
          pending_action: command() | nil,
          next_ts_id: non_neg_integer(),
          window_ack_size: non_neg_integer(),
          streams: %{Message.stream_id() => StreamContext.t()}
        }

  @enforce_keys [:uri, :stream_key]
  defstruct @enforce_keys ++
              [
                :socket,
                :pending_peer,
                :pending_action,
                chunk_parser: ChunkParser.new(),
                next_ts_id: 2,
                window_ack_size: @default_window_ack_size,
                streams: %{}
              ]

  @spec add_stream(t(), ExRTMP.Message.stream_id()) :: t()
  def add_stream(state, stream_id) do
    stream = %StreamContext{id: stream_id}
    %{state | streams: Map.put(state.streams, stream_id, stream)}
  end

  @spec set_stream_pending_action(t(), Message.stream_id(), command(), GenServer.from()) :: t()
  def set_stream_pending_action(state, stream_id, action, from) do
    streams =
      Map.update!(state.streams, stream_id, fn stream ->
        %{stream | pending_action: action, pending_peer: from}
      end)

    %{state | streams: streams}
  end

  @spec clear_stream_pending_action(t(), Message.stream_id()) :: t()
  def clear_stream_pending_action(state, stream_id) do
    streams =
      Map.update!(state.streams, stream_id, fn stream ->
        %{stream | pending_action: nil, pending_peer: nil}
      end)

    %{state | streams: streams}
  end

  @spec delete_stream(t(), Message.stream_id()) :: t()
  def delete_stream(state, stream_id) do
    %{state | streams: Map.delete(state.streams, stream_id)}
  end
end
