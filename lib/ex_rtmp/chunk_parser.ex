defmodule ExRTMP.ChunkParser do
  @moduledoc false

  alias ExRTMP.{Chunk, Message}

  @type t :: %__MODULE__{
          unprocessed_data: binary(),
          messages: %{Chunk.stream_id() => Message.t()},
          chunk_size: non_neg_integer(),
          message_first_chunk: %{Chunk.stream_id() => tuple()}
        }

  defstruct [:unprocessed_data, :messages, :message_first_chunk, chunk_size: 128]

  @spec new() :: t()
  def new() do
    %__MODULE__{
      unprocessed_data: <<>>,
      messages: %{},
      message_first_chunk: %{}
    }
  end

  @spec process(binary(), t()) :: {[Message.t()], t()}
  def process(data, parser) do
    do_process(parser.unprocessed_data <> data, parser)
  end

  defp do_process(data, parser, acc \\ []) do
    with {:ok, chunk, rest} <- Chunk.parse_header(data),
         {chunk, parser} <- set_missing_fields(chunk, parser),
         payload_size <- get_chunk_payload_size(parser, chunk),
         <<payload::binary-size(payload_size), rest::binary>> <- rest do
      message = Map.get(parser.messages, chunk.stream_id, Message.new(chunk))

      {parser, acc} =
        case Message.append(message, payload) do
          {:ok, %{type: 1, payload: chunk_size}} ->
            parser = %{
              parser
              | messages: Map.delete(parser.messages, chunk.stream_id),
                chunk_size: chunk_size
            }

            {parser, acc}

          {:ok, message} ->
            parser = %{parser | messages: Map.delete(parser.messages, chunk.stream_id)}
            {parser, [message | acc]}

          {:more, message} ->
            parser = %{parser | messages: Map.put(parser.messages, chunk.stream_id, message)}
            {parser, acc}
        end

      do_process(rest, parser, acc)
    else
      _ ->
        {Enum.reverse(acc), %{parser | unprocessed_data: data}}
    end
  end

  defp set_missing_fields(chunk, parser) when is_map_key(parser.messages, chunk.stream_id) do
    {chunk, parser}
  end

  defp set_missing_fields(%{fmt: 0} = chunk, parser) do
    tuple =
      {chunk.timestamp, 0, chunk.message_length, chunk.message_type_id, chunk.message_stream_id}

    message_first_chunk = Map.put(parser.message_first_chunk, chunk.stream_id, tuple)
    {chunk, %{parser | message_first_chunk: message_first_chunk}}
  end

  defp set_missing_fields(chunk, parser) do
    {timestamp, timestamp_delta, message_size, message_type, message_stream_id} =
      Map.fetch!(parser.message_first_chunk, chunk.stream_id)

    timestamp_delta = chunk.timestamp || timestamp_delta

    chunk = %{
      chunk
      | timestamp: timestamp_delta + timestamp,
        message_length: chunk.message_length || message_size,
        message_type_id: chunk.message_type_id || message_type,
        message_stream_id: chunk.message_stream_id || message_stream_id
    }

    message_first_chunk =
      Map.put(
        parser.message_first_chunk,
        chunk.stream_id,
        {chunk.timestamp, timestamp_delta, chunk.message_length, chunk.message_type_id,
         chunk.message_stream_id}
      )

    {chunk, %{parser | message_first_chunk: message_first_chunk}}
  end

  defp get_chunk_payload_size(parser, chunk) do
    remaining_bytes =
      if message = Map.get(parser.messages, chunk.stream_id),
        do: message.size - message.current_size,
        else: chunk.message_length

    min(parser.chunk_size, remaining_bytes)
  end
end
