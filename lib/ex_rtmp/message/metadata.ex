defmodule ExRTMP.Message.Metadata do
  @moduledoc """
  Module describing metadata message.
  """

  @type t :: %__MODULE__{
          data: map()
        }

  defstruct [:data]

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(%ExRTMP.Message.Metadata{data: data}) do
      [
        AMF0.serialize("@setDataFrame"),
        AMF0.serialize("onMetaData"),
        AMF0.serialize({:ecma_array, data})
      ]
    end
  end
end
