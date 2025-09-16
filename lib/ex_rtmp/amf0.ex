defmodule ExRTMP.AMF0 do
  @moduledoc """
  AMF0 parser.
  """

  @spec parse(binary()) :: list()
  def parse(data), do: do_parse(data, [])

  @spec serialize(any()) :: iodata()
  def serialize(true), do: <<0x01, 1>>
  def serialize(false), do: <<0x01, 0>>
  def serialize(nil), do: <<0x05>>
  def serialize(value) when is_number(value), do: <<0x00::8, value::float-64>>
  def serialize(atom) when is_atom(atom), do: serialize(to_string(atom))
  def serialize(str) when is_binary(str), do: <<0x02::8, byte_size(str)::16, str::binary>>

  def serialize(map) when is_map(map) do
    pairs =
      Enum.map(map, fn {key, value} ->
        [<<byte_size(key)::16, key::binary>>, serialize(value)]
      end)

    [0x03, pairs, 0, 0, 0]
  end

  defp do_parse(<<>>, acc), do: Enum.reverse(acc)

  defp do_parse(data, acc) do
    case parse_value(data) do
      {:object_start, rest} ->
        {obj, rest} = parse_object(rest, %{})
        do_parse(rest, [obj | acc])

      {value, rest} ->
        do_parse(rest, [value | acc])
    end
  end

  defp parse_value(<<0x00::8, number::float-64, rest::binary>>), do: {number, rest}
  defp parse_value(<<0x01::8, boolean::8, rest::binary>>), do: {boolean == 1, rest}
  defp parse_value(<<0x03::8, rest::binary>>), do: {:object_start, rest}
  defp parse_value(<<0x05::8, rest::binary>>), do: {nil, rest}

  defp parse_value(<<0x02::8, str_len::16, str::binary-size(str_len), rest::binary>>),
    do: {str, rest}

  defp parse_value(<<0x08::8, count::32, rest::binary>>) do
    {list, rest} =
      Enum.map_reduce(1..count, rest, fn _idx, rest ->
        {key, rest} = parse_object_key(rest)
        {value, rest} = parse_value(rest)
        {{key, value}, rest}
      end)

    <<0, 0, 9, rest::binary>> = rest
    {list, rest}
  end

  defp parse_object(rest, obj) do
    case parse_object_key(rest) do
      {:object_end, rest} ->
        {obj, rest}

      {key, rest} ->
        {value, rest} = parse_value(rest)
        parse_object(rest, Map.put(obj, key, value))
    end
  end

  defp parse_object_key(<<0::16, 0x09, rest::binary>>), do: {:object_end, rest}
  defp parse_object_key(<<str_len::16, str::binary-size(str_len), rest::binary>>), do: {str, rest}
  defp parse_object_key(_data), do: :error
end
