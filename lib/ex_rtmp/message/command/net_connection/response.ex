defmodule ExRTMP.Message.Command.NetConnection.Response do
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

  @spec connect_failed(String.t()) :: t()
  def connect_failed(reason) do
    error(1, "NetConnection.Connect.Failed", reason)
  end

  @spec create_stream_failed(number(), String.t()) :: t()
  def create_stream_failed(transaction_id, reason) do
    error(transaction_id, "NetConnection.CreateStream.Failed", reason)
  end

  def error(transaction_id, code, description) do
    %__MODULE__{
      result: "_error",
      transaction_id: transaction_id,
      command_object: %{},
      data: %{
        "level" => "error",
        "code" => code,
        "description" => description
      }
    }
  end

  defimpl ExRTMP.Message.Serializer do
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
