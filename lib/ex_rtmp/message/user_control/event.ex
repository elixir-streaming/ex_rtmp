defmodule ExRTMP.Message.UserControl.Event do
  @moduledoc """
  Module describing user control message payload.
  """

  @type type ::
          :stream_begin
          | :stream_eof
          | :stream_dry
          | :set_buffer_length
          | :stream_is_recorded
          | :ping_request
          | :ping_response

  @type t :: %__MODULE__{
          type: type(),
          data: any()
        }

  defstruct [:type, :data]

  @doc """
  Creates a new user control event message payload.
  """
  @spec new(type(), any()) :: t()
  def new(type, data) do
    %__MODULE__{type: type, data: data}
  end

  @doc """
  Parses a binary into a user control event message payload.

  ## Examples

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 0, 0, 0, 0, 1>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :stream_begin, data: 1}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 1, 0, 0, 0, 3>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :stream_eof, data: 3}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 2, 0, 0, 0, 5>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :stream_dry, data: 5}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 3, 0, 0, 0, 4, 0, 0, 3, 232>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :set_buffer_length, data: {4, 1000}}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 4, 0, 0, 0, 2>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :stream_is_recorded, data: 2}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 6, 104, 220, 201, 210>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :ping_request, data: 1759300050}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 7, 104, 220, 201, 210>>)
      {:ok, %ExRTMP.Message.UserControl.Event{type: :ping_response, data: 1759300050}}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 8, 0, 1, 0, 0, 0, 42>>)
      {:error, :unknown_type}

      iex> ExRTMP.Message.UserControl.Event.parse(<<0, 3, 0, 1, 0, 0, 0, 42>>)
      {:error, :invalid_payload}
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, atom()}
  def parse(<<type::16, rest::binary>> = _payload) when type in 0..7 do
    case parse_payload(type, rest) do
      {:ok, event_type, data} -> {:ok, %__MODULE__{type: event_type, data: data}}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_data), do: {:error, :unknown_type}

  defp parse_payload(0, <<stream_id::32>>), do: {:ok, :stream_begin, stream_id}
  defp parse_payload(1, <<stream_id::32>>), do: {:ok, :stream_eof, stream_id}
  defp parse_payload(2, <<stream_id::32>>), do: {:ok, :stream_dry, stream_id}

  defp parse_payload(3, <<stream_id::32, buffer_length::32>>),
    do: {:ok, :set_buffer_length, {stream_id, buffer_length}}

  defp parse_payload(4, <<stream_id::32>>), do: {:ok, :stream_is_recorded, stream_id}
  defp parse_payload(6, <<timestamp::32>>), do: {:ok, :ping_request, timestamp}
  defp parse_payload(7, <<timestamp::32>>), do: {:ok, :ping_response, timestamp}
  defp parse_payload(_type, _data), do: {:error, :invalid_payload}

  defimpl ExRTMP.Message.Serializer do
    def serialize(%{type: type, data: data}) do
      data_bin =
        case {type, data} do
          {:stream_begin, stream_id} -> <<stream_id::32>>
          {:stream_eof, stream_id} -> <<stream_id::32>>
          {:stream_dry, stream_id} -> <<stream_id::32>>
          {:set_buffer_length, {stream_id, buffer_length}} -> <<stream_id::32, buffer_length::32>>
          {:stream_is_recorded, stream_id} -> <<stream_id::32>>
          {:ping_request, timestamp} -> <<timestamp::32>>
          {:ping_response, timestamp} -> <<timestamp::32>>
        end

      <<type_to_int(type)::16, data_bin::binary>>
    end

    defp type_to_int(:stream_begin), do: 0
    defp type_to_int(:stream_eof), do: 1
    defp type_to_int(:stream_dry), do: 2
    defp type_to_int(:set_buffer_length), do: 3
    defp type_to_int(:stream_is_recorded), do: 4
    defp type_to_int(:ping_request), do: 6
    defp type_to_int(:ping_response), do: 7
  end
end
