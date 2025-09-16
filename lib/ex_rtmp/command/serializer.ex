defprotocol ExRTMP.Command.Serializer do
  @spec serialize(t()) :: iodata()
  def serialize(command)
end
