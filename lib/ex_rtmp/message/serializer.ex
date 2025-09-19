defprotocol ExRTMP.Message.Serializer do
  @spec serialize(t()) :: iodata()
  def serialize(payload)
end
