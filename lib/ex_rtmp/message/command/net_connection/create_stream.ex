defmodule ExRTMP.Message.Command.NetConnection.CreateStream do
  @moduledoc """
  Module describing Connect command.
  """

  @type t :: %__MODULE__{
          transaction_id: number(),
          properties: map(),
          user_arguments: map() | nil
        }

  defstruct [:transaction_id, :properties, :user_arguments]

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(createStream) do
      [
        AMF0.serialize("createStream"),
        AMF0.serialize(createStream.transaction_id),
        AMF0.serialize(nil),
        if(createStream.user_arguments,
          do: AMF0.serialize(createStream.user_arguments),
          else: <<>>
        )
      ]
    end
  end
end
