defmodule ExRTMP.Message.Command.NetConnection.Connect do
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

    def serialize(%{user_arguments: user_arguments} = connect) do
      [
        AMF0.serialize("connect"),
        AMF0.serialize(connect.transaction_id),
        AMF0.serialize(connect.properties),
        if(user_arguments, do: AMF0.serialize(user_arguments), else: <<>>)
      ]
    end
  end
end
