defmodule ExRTMP.Command.NetConnection.Response do
  @moduledoc """
  Module describing command response
  """

  alias ExRTMP.AMF0

  @type t :: %__MODULE__{
          result: String.t(),
          transaction_id: number(),
          command_object: map(),
          data: any()
        }

  defstruct [:result, :transaction_id, :command_object, :data]

  @spec ok(number()) :: t()
  @spec ok(number(), keyword() | nil) :: t()
  def ok(transaction_id, opts \\ []) do
    struct(%__MODULE__{result: "_result", transaction_id: transaction_id}, opts)
  end

  defimpl ExRTMP.Command.Serializer do
    def serialize(response) do
      [
        AMF0.serialize(response.result),
        AMF0.serialize(response.transaction_id),
        AMF0.serialize(response.command_object),
        if(response.data, do: AMF0.serialize(response.data), else: <<>>)
      ]
    end
  end
end
