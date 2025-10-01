defmodule ExRTMP.Message do
  @moduledoc """
  Module describing a message.
  """

  require Logger

  alias __MODULE__.Command.NetConnection.{Connect, CreateStream, Response}
  alias __MODULE__.Command.NetStream.{DeleteStream, OnStatus, Play, Publish}
  alias __MODULE__.Metadata
  alias __MODULE__.UserControl.Event
  alias ExRTMP.Chunk

  @type stream_id :: non_neg_integer()

  @type t :: %__MODULE__{
          type: non_neg_integer(),
          size: non_neg_integer() | nil,
          current_size: non_neg_integer() | nil,
          payload: iodata() | struct() | non_neg_integer(),
          timestamp: non_neg_integer(),
          stream_id: stream_id()
        }

  defstruct [:type, :size, :current_size, :payload, :timestamp, :stream_id]

  @doc false
  @spec new(Chunk.t()) :: t()
  def new(%Chunk{} = chunk) do
    %__MODULE__{
      type: chunk.message_type_id,
      size: chunk.message_length,
      current_size: 0,
      timestamp: chunk.timestamp,
      stream_id: chunk.message_stream_id,
      payload: []
    }
  end

  @doc """
  Creates a new `Message`.
  """
  @spec new(iodata() | struct(), keyword()) :: t()
  def new(payload, opts) do
    struct(%__MODULE__{payload: payload}, opts)
  end

  # Chunk stream control messages
  @doc """
  Builds a `Set Chunk Size` message.
  """
  @spec chunk_size(non_neg_integer()) :: t()
  def chunk_size(chunk_size) do
    new(<<0::1, chunk_size::31>>, type: 1, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds an `Abort` message.
  """
  @spec abort(non_neg_integer()) :: t()
  def abort(stream_id) do
    new(<<stream_id::32>>, type: 2, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds an `Acknowledgment` message.
  """
  @spec aknowledgment(non_neg_integer()) :: t()
  def aknowledgment(received_bytes) do
    new(<<received_bytes::32>>, type: 3, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds a `Window Acknowledgment Size` message.
  """
  @spec window_acknowledgment_size(non_neg_integer()) :: t()
  def window_acknowledgment_size(size) do
    new(<<size::32>>, type: 5, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds a `Peer Bandwidth` message.
  """
  @spec peer_bandwidth(non_neg_integer(), 0..2) :: t()
  def peer_bandwidth(size, limit_type \\ 2) do
    new(<<size::32, limit_type::8>>, type: 6, timestamp: 0, stream_id: 0)
  end

  # User control messages
  @doc """
  Builds a `User Control` message.
  """
  @spec stream_begin(non_neg_integer()) :: t()
  def stream_begin(stream_id) do
    new(Event.new(:stream_begin, stream_id), type: 4, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds a `User Control` message.
  """
  @spec ping_response(non_neg_integer()) :: t()
  def ping_response(timestamp) do
    new(Event.new(:ping_response, timestamp), type: 4, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds a `Command` message.
  """
  @spec command(any()) :: t()
  @spec command(any(), non_neg_integer()) :: t()
  def command(command, stream_id \\ 0) do
    new(command, type: 20, timestamp: 0, stream_id: stream_id)
  end

  @doc """
  Builds a `Metadata` message.
  """
  @spec metadata(map(), non_neg_integer()) :: t()
  def metadata(metadata, stream_id) do
    new(%Metadata{data: metadata}, type: 18, timestamp: 0, stream_id: stream_id)
  end

  @doc false
  @spec append(t(), binary()) :: {:ok, t()} | {:more, t()}
  def append(%__MODULE__{payload: payload} = msg, chunk_payload) do
    current_size = msg.current_size + byte_size(chunk_payload)
    payload = [chunk_payload | payload]

    if current_size == msg.size do
      msg = %{msg | current_size: nil, payload: Enum.reverse(payload)}
      {:ok, parse_payload(msg)}
    else
      {:more, %{msg | current_size: current_size, payload: payload}}
    end
  end

  @doc """
  Serializes the message.

  The following options may be provided:

    * `:chunk_size` - The size of each chunk (default: 128)
    * `:chunk_stream_id` - The chunk stream id to use (default: 2)
  """
  @spec serialize(t(), keyword()) :: iodata()
  def serialize(message, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 128)
    chunk_stream_id = Keyword.get(opts, :chunk_stream_id, 2)

    payload =
      if is_struct(message.payload),
        do: ExRTMP.Message.Serializer.serialize(message.payload),
        else: message.payload

    payload = IO.iodata_to_binary(payload)
    entries = ceil(byte_size(payload) / chunk_size)

    first_chunk = %Chunk{
      fmt: 0,
      stream_id: chunk_stream_id,
      payload: binary_part(payload, 0, min(byte_size(payload), chunk_size)),
      timestamp: message.timestamp,
      message_length: byte_size(payload),
      message_type_id: message.type,
      message_stream_id: message.stream_id
    }

    2..entries//1
    |> Stream.map(fn idx ->
      offset = (idx - 1) * chunk_size
      size = min(byte_size(payload) - offset, chunk_size)
      binary_part(payload, offset, size)
    end)
    |> Stream.map(&%Chunk{payload: &1, stream_id: chunk_stream_id, fmt: 3})
    |> Enum.map(&Chunk.serialize/1)
    |> then(&[Chunk.serialize(first_chunk) | &1])
  end

  defp parse_payload(%__MODULE__{type: 1, payload: payload} = msg) do
    <<0::1, chunk_size::31>> = IO.iodata_to_binary(payload)
    %{msg | payload: chunk_size}
  end

  defp parse_payload(%__MODULE__{type: 3, payload: payload} = msg) do
    <<received_bytes::32>> = IO.iodata_to_binary(payload)
    %{msg | payload: received_bytes}
  end

  defp parse_payload(%__MODULE__{type: 4, payload: payload} = msg) do
    {:ok, event} = Event.parse(IO.iodata_to_binary(payload))
    %{msg | payload: event}
  end

  defp parse_payload(%__MODULE__{type: 5, payload: payload} = msg) do
    <<win_size::32>> = IO.iodata_to_binary(payload)
    %{msg | payload: win_size}
  end

  defp parse_payload(%__MODULE__{type: 6, payload: payload} = msg) do
    <<win_size::32, limit_type::8>> = IO.iodata_to_binary(payload)
    %{msg | payload: {win_size, limit_type}}
  end

  defp parse_payload(%__MODULE__{type: 18, payload: payload} = msg) do
    payload =
      case ExRTMP.AMF0.parse(IO.iodata_to_binary(payload)) do
        ["@setDataFrame", "onMetaData", metadata] ->
          %Metadata{data: metadata}

        ["onMetaData", metadata] ->
          %Metadata{data: metadata}

        other ->
          Logger.warning("Unknown parsed metadata: #{inspect(other)}")
          payload
      end

    %{msg | payload: payload}
  end

  @doc false
  defp parse_payload(%__MODULE__{type: 20, payload: payload} = msg) do
    payload =
      case ExRTMP.AMF0.parse(IO.iodata_to_binary(payload)) do
        ["connect", transaction_id, properties | _rest] ->
          %Connect{transaction_id: transaction_id, properties: properties}

        ["createStream", transaction_id | _rest] ->
          %CreateStream{transaction_id: transaction_id}

        [result, transaction_id, command_object, data] when result in ["_result", "_error"] ->
          %Response{
            result: result,
            transaction_id: trunc(transaction_id),
            command_object: command_object,
            data: data
          }

        ["publish", transaction_id, nil, name, type] ->
          Publish.new(transaction_id, name, type)

        ["deleteStream", transaction_id, nil, stream_id] ->
          DeleteStream.new(transaction_id, stream_id)

        ["play", transaction_id, nil, stream_name | opts] ->
          play_opts =
            case opts do
              [] -> []
              [start] -> [start: start]
              [start, duration] -> [start: start, duration: duration]
              [start, duration, reset] -> [start: start, duration: duration, reset: reset]
            end

          Play.new(transaction_id, stream_name, play_opts)

        ["onStatus", _ts_id, nil, info] ->
          %OnStatus{info: info}

        other ->
          Logger.warning("Unknown command: #{inspect(List.first(other))}")
          payload
      end

    %{msg | payload: payload}
  end

  defp parse_payload(msg), do: msg
end
