defmodule ExRTMP.Message.Command.NetStream.Publish do
  @moduledoc """
  Struct representing a "publish" command message for RTMP NetStream.
  """

  @type publishing_type :: :live | :record | :append

  @type t :: %__MODULE__{
          transaction_id: number(),
          name: String.t(),
          type: publishing_type()
        }

  defstruct [:transaction_id, :name, :type]

  @spec new(number(), String.t(), String.t()) :: t()
  def new(transaction_id, name, type) do
    %__MODULE__{
      transaction_id: transaction_id,
      name: name,
      type: String.to_existing_atom(type)
    }
  end

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(publish) do
      [
        AMF0.serialize("publish"),
        AMF0.serialize(publish.transaction_id),
        AMF0.serialize(nil),
        AMF0.serialize(publish.name),
        AMF0.serialize(publish.type)
      ]
    end
  end
end
