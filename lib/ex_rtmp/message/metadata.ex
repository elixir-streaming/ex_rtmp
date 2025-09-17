defmodule ExRTMP.Message.Metadata do
  @moduledoc """
  Module describing metadata message.
  """

  @type t :: %__MODULE__{
          data: map()
        }

  defstruct [:data]
end
