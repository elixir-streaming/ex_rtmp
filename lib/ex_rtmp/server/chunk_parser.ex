defmodule ExRTMP.Server.ChunkParser do
  @moduledoc false

  alias ExRTMP.{Chunk, Message}

  @type t :: %__MODULE__{
          unprocessed_data: binary(),
          messages: %{Chunk.stream_id() => Message.t()},
          last_messages: %{Chunk.stream_id() => Message.t()},
          chunk_size: non_neg_integer()
        }

  defstruct [:unprocessed_data, :messages, :last_messages, chunk_size: 128]

  @spec new() :: t()
  def new() do
    %__MODULE__{
      unprocessed_data: <<>>,
      messages: %{},
      last_messages: %{}
    }
  end

  @spec process(binary(), t()) :: {[Message.t()], t()}
  def process(data, parser) do
    do_process(parser.unprocessed_data <> data, parser)
  end

  defp do_process(data, parser, acc \\ []) do
    with {:ok, chunk, rest} <- Chunk.parse_header(data),
         {chunk, payload_size} <- get_chunk_payload_size(parser, chunk),
         <<payload::binary-size(payload_size), rest::binary>> <- rest do
      chunk = %{chunk | payload: payload}
      message = Map.get(parser.messages, chunk.stream_id)
      message = (message && Message.append_chunk(message, chunk)) || Message.new(chunk)

      {parser, acc} =
        if Message.complete?(message) do
          message = Message.parse_payload(message)

          parser = %{
            parser
            | messages: Map.delete(parser.messages, chunk.stream_id),
              last_messages: Map.put(parser.last_messages, chunk.stream_id, message)
          }

          {parser, [message | acc]}
        else
          parser = %{parser | messages: Map.put(parser.messages, chunk.stream_id, message)}
          {parser, acc}
        end

      do_process(rest, parser, acc)
    else
      _ ->
        {Enum.reverse(acc), %{parser | unprocessed_data: data}}
    end
  end

  defp get_chunk_payload_size(parser, chunk) do
    message = Map.get(parser.messages, chunk.stream_id)
    last_message = Map.get(parser.last_messages, chunk.stream_id)

    remaining_bytes =
      cond do
        not is_nil(message) -> message.size - IO.iodata_length(message.payload)
        chunk.fmt < 2 -> chunk.message_length
        true -> last_message.size
      end

    payload_size = min(parser.chunk_size, remaining_bytes)

    if chunk.fmt != 0 and is_nil(message) do
      chunk = %{
        chunk
        | timestamp: chunk.timestamp || last_message.timestamp,
          message_length: chunk.message_length || last_message.size,
          message_type_id: chunk.message_type_id || last_message.type,
          message_stream_id: chunk.message_stream_id || last_message.stream_id
      }

      {chunk, payload_size}
    else
      {chunk, payload_size}
    end
  end
end
