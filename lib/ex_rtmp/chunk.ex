defmodule ExRTMP.Chunk do
  @moduledoc """
  RTMP Chunk structure
  """

  @type payload_size :: non_neg_integer()
  @type stream_id :: non_neg_integer()

  @type t :: %__MODULE__{
          fmt: 0..3,
          stream_id: stream_id(),
          timestamp: non_neg_integer() | nil,
          message_length: non_neg_integer() | nil,
          message_type_id: non_neg_integer() | nil,
          message_stream_id: non_neg_integer() | nil,
          payload: binary() | nil
        }

  defstruct [
    :fmt,
    :stream_id,
    :timestamp,
    :message_length,
    :message_type_id,
    :message_stream_id,
    :payload
  ]

  @spec parse_header(binary()) :: {:ok, t(), binary()} | :more
  def parse_header(data) do
    with {:ok, chunk, rest} <- parse_stream_id(data),
         {:ok, chunk, rest} <- parse_message_header(chunk, rest),
         {:ok, chunk, rest} <- parse_extended_timestamp(chunk, rest) do
      {:ok, chunk, rest}
    end
  end

  @spec serialize(t()) :: iodata()
  def serialize(%__MODULE__{} = chunk) do
    timestamp = if chunk.timestamp, do: <<chunk.timestamp::24>>, else: <<>>
    length = if chunk.message_length, do: <<chunk.message_length::24>>, else: <<>>
    type_id = if chunk.message_type_id, do: <<chunk.message_type_id::8>>, else: <<>>

    msg_stream_id =
      if chunk.message_stream_id, do: <<chunk.message_stream_id::32-little>>, else: <<>>

    [
      <<chunk.fmt::2, encode_stream_id(chunk.stream_id)::bitstring>>,
      timestamp,
      length,
      type_id,
      msg_stream_id,
      chunk.payload
    ]
  end

  defp parse_stream_id(data) do
    case data do
      <<fmt::2, 0::6, cs_id::8, rest::binary>> ->
        {:ok, %__MODULE__{fmt: fmt, stream_id: cs_id + 64}, rest}

      <<fmt::2, 1::6, cs_id::16, rest::binary>> ->
        {:ok, %__MODULE__{fmt: fmt, stream_id: cs_id + 64}, rest}

      <<fmt::2, cs_id::6, rest::binary>> ->
        {:ok, %__MODULE__{fmt: fmt, stream_id: cs_id}, rest}

      _ ->
        :more
    end
  end

  defp parse_message_header(chunk, data) do
    case {chunk.fmt, data} do
      {0,
       <<timestamp::24, length::24, type_id::8, msg_stream_id::integer-32-little, rest::binary>>} ->
        chunk = %{
          chunk
          | timestamp: timestamp,
            message_length: length,
            message_type_id: type_id,
            message_stream_id: msg_stream_id
        }

        {:ok, chunk, rest}

      {1, <<timestamp::24, length::24, type_id::8, rest::binary>>} ->
        chunk = %{chunk | timestamp: timestamp, message_length: length, message_type_id: type_id}
        {:ok, chunk, rest}

      {2, <<timestamp::24, rest::binary>>} ->
        {:ok, %{chunk | timestamp: timestamp}, rest}

      {3, rest} ->
        {:ok, chunk, rest}

      _ ->
        :more
    end
  end

  defp parse_extended_timestamp(%{timestamp: 0xFFFFFF} = chunk, <<ts::32, rest::binary>>) do
    {:ok, %{chunk | timestamp: ts}, rest}
  end

  defp parse_extended_timestamp(%{timestamp: 0xFFFFFF}, _rest), do: :more
  defp parse_extended_timestamp(chunk, data), do: {:ok, chunk, data}

  defp encode_stream_id(stream_id) when stream_id in 2..63, do: <<stream_id::6>>
  defp encode_stream_id(stream_id) when stream_id in 64..319, do: <<0::6, stream_id - 64::8>>
  defp encode_stream_id(stream_id) when stream_id >= 320, do: <<1::6, stream_id - 64::16>>
end
