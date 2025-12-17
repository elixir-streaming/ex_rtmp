defmodule ExRTMP.Message.Command.NetStream.FCPublish do
  @moduledoc """
  Struct representing an "FCPublish" command message for RTMP NetStream.
  """

  @type t :: %__MODULE__{
          transaction_id: number(),
          name: String.t()
        }

  defstruct [:transaction_id, :name]

  @spec new(number(), String.t()) :: t()
  def new(transaction_id, name) do
    %__MODULE__{transaction_id: transaction_id, name: name}
  end

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(publish) do
      IO.iodata_to_binary([
        AMF0.serialize("FCPublish"),
        AMF0.serialize(publish.transaction_id),
        AMF0.serialize(nil),
        AMF0.serialize(publish.name)
      ])
    end
  end
end
