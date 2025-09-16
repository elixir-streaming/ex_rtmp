defmodule ExRTMP.Command.NetStream.OnStatus do
  @moduledoc false

  @type level :: :status | :error | :warning

  @type t :: %__MODULE__{info: map()}

  defstruct [:info]

  @spec new(String.t()) :: t()
  def new(code, level \\ :status, description \\ nil) do
    info = %{
      "code" => code,
      "level" => level,
      "description" => description
    }

    %__MODULE__{info: info}
  end

  @spec publish_ok() :: t()
  def publish_ok(), do: new("NetStream.Publish.Start")

  defimpl ExRTMP.Command.Serializer do
    alias ExRTMP.AMF0

    def serialize(command) do
      [
        AMF0.serialize("onStatus"),
        AMF0.serialize(0),
        AMF0.serialize(nil),
        AMF0.serialize(command.info)
      ]
    end
  end
end
