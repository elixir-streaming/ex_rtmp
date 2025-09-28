defmodule ExRTMP.Message.Command.NetStream.Play do
  @moduledoc """
  Module representing a `NetStream.Play` command message.
  """

  @type t :: %__MODULE__{
          transaction_id: float(),
          name: String.t(),
          start: integer(),
          duration: integer(),
          reset: boolean()
        }

  defstruct [:transaction_id, :name, start: -2000, duration: -1, reset: true]

  @spec new(float(), String.t(), keyword()) :: t()
  def new(transaction_id, name, opts \\ []) do
    struct(%__MODULE__{transaction_id: transaction_id, name: name}, opts)
  end

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(play) do
      [
        AMF0.serialize("play"),
        AMF0.serialize(play.transaction_id),
        AMF0.serialize(nil),
        AMF0.serialize(play.name),
        AMF0.serialize(play.start),
        AMF0.serialize(play.duration),
        AMF0.serialize(play.reset)
      ]
    end
  end
end
