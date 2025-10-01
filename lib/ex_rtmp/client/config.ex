defmodule ExRTMP.Client.Config do
  @moduledoc false

  @default_port 1935
  @default_config [uri: nil, stream_key: nil]

  @spec validate!(Keyword.t()) :: Keyword.t()
  def validate!(opts) do
    @default_config
    |> Keyword.merge(opts)
    |> validate_option([])
  end

  defp validate_option([], acc), do: acc

  defp validate_option([{:uri, nil} | _rest], _acc) do
    raise ArgumentError, "The :uri option is required"
  end

  defp validate_option([{:uri, uri} | rest], acc) do
    case URI.parse(uri) do
      %URI{scheme: "rtmp", host: host} = uri when is_binary(host) ->
        acc = [{:uri, %{uri | port: uri.port || @default_port}} | acc]
        validate_option(rest, acc)

      _ ->
        raise ArgumentError, "The :uri option is not a valid RTMP URI"
    end
  end

  defp validate_option([{:stream_key, nil} | _rest], _acc) do
    raise ArgumentError, "The :stream_key option is required"
  end

  defp validate_option([{key, value} | rest], acc) do
    validate_option(rest, [{key, value} | acc])
  end
end
