defmodule ExRTMP.Message.Command.NetStream.OnStatus do
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

  @spec publish_bad_stream() :: t()
  def publish_bad_stream() do
    new("NetStream.Publish.BadStream", :error, "Unknown stream")
  end

  @spec publish_failed(String.t()) :: t()
  def publish_failed(reason) do
    new("NetStream.Publish.Failed", :error, reason)
  end

  @spec play_ok() :: t()
  def play_ok(), do: new("NetStream.Play.Start")

  @spec play_bad_stream() :: t()
  def play_bad_stream() do
    new("NetStream.Play.BadStream", :error, "Unknown stream")
  end

  @spec play_failed(String.t()) :: t()
  def play_failed(reason) do
    new("NetStream.Play.Failed", :error, reason)
  end

  defimpl ExRTMP.Message.Serializer do
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
