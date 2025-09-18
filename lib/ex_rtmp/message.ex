defmodule ExRTMP.Message do
  @moduledoc """
  Module describing a message.
  """

  require Logger

  alias __MODULE__.Command.NetConnection.{Connect, CreateStream}
  alias __MODULE__.Command.NetStream.{DeleteStream, Publish}
  alias __MODULE__.Metadata
  alias ExRTMP.Chunk

  @type t :: %__MODULE__{
          type: non_neg_integer(),
          size: non_neg_integer(),
          payload: iodata() | struct(),
          timestamp: non_neg_integer(),
          stream_id: non_neg_integer()
        }

  defstruct [:type, :size, :payload, :timestamp, :stream_id]

  @spec new(Chunk.t()) :: t()
  def new(%Chunk{} = chunk) do
    %__MODULE__{
      type: chunk.message_type_id,
      size: chunk.message_length,
      payload: chunk.payload,
      timestamp: chunk.timestamp,
      stream_id: chunk.message_stream_id
    }
  end

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
  @spec stream_begin(non_neg_integer()) :: t()
  def stream_begin(stream_id) do
    new(<<0::16, stream_id::32>>, type: 4, timestamp: 0, stream_id: 0)
  end

  @doc """
  Builds a `Command` message.
  """
  @spec command(any()) :: t()
  @spec command(any(), non_neg_integer()) :: t()
  def command(command, stream_id \\ 0) do
    new(command, type: 20, timestamp: 0, stream_id: stream_id)
  end

  @spec append_chunk(t(), Chunk.t()) :: t()
  def append_chunk(%__MODULE__{payload: payload} = msg, chunk) do
    %{msg | payload: [payload, chunk.payload]}
  end

  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{payload: payload, size: size}) do
    IO.iodata_length(payload) >= size
  end

  @doc false
  @spec parse_payload(t()) :: t()
  def parse_payload(%__MODULE__{type: 20, payload: payload} = msg) do
    payload =
      case ExRTMP.AMF0.parse(IO.iodata_to_binary(payload)) do
        ["connect", transaction_id, properties | _rest] ->
          %Connect{transaction_id: transaction_id, properties: properties}

        ["createStream", transaction_id | _rest] ->
          %CreateStream{transaction_id: transaction_id}

        ["publish", transaction_id, nil, name, type] ->
          Publish.new(transaction_id, name, type)

        ["deleteStream", transaction_id, nil, stream_id] ->
          DeleteStream.new(transaction_id, stream_id)

        other ->
          Logger.warning("Unknown command: #{inspect(List.first(other))}")
          payload
      end

    %{msg | payload: payload}
  end

  def parse_payload(%__MODULE__{type: 18, payload: payload} = msg) do
    payload =
      case ExRTMP.AMF0.parse(IO.iodata_to_binary(payload)) do
        ["@setDataFrame", "onMetaData", metadata] ->
          %Metadata{data: Map.new(metadata)}

        ["onMetaData", metadata] ->
          %Metadata{data: Map.new(metadata)}

        other ->
          Logger.warning("Unknown parsed metadata: #{inspect(other)}")
          payload
      end

    %{msg | payload: payload}
  end

  def parse_payload(msg), do: msg

  @spec serialize(t()) :: iodata()
  def serialize(message) do
    payload =
      if is_struct(message.payload),
        do: ExRTMP.Message.Serializer.serialize(message.payload),
        else: message.payload

    payload = IO.iodata_to_binary(payload)

    payload
    |> :binary.bin_to_list()
    |> Enum.chunk_every(128)
    |> Enum.map(&%Chunk{payload: &1, stream_id: 2, fmt: 3})
    |> then(fn [first | rest] ->
      first = %{
        first
        | fmt: 0,
          timestamp: message.timestamp,
          message_length: byte_size(payload),
          message_type_id: message.type,
          message_stream_id: message.stream_id
      }

      [first | rest]
    end)
    |> Enum.map(&Chunk.serialize/1)
  end
end
