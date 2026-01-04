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

  defstruct [:name, :type, transaction_id: 0.0]

  @spec new(String.t(), String.t()) :: t()
  def new(name, type) do
    %__MODULE__{name: name, type: String.to_existing_atom(type)}
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
