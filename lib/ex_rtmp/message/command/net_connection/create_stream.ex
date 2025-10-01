defmodule ExRTMP.Message.Command.NetConnection.CreateStream do
  @moduledoc """
  Module describing Connect command.
  """

  @type t :: %__MODULE__{
          transaction_id: number(),
          properties: map() | nil
        }

  defstruct [:transaction_id, :properties]

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(createStream) do
      [
        AMF0.serialize("createStream"),
        AMF0.serialize(createStream.transaction_id),
        AMF0.serialize(createStream.properties)
      ]
    end
  end
end
