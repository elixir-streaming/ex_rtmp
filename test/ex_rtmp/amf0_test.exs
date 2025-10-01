defmodule ExRTMP.AMF0Test do
  use ExUnit.Case, async: true

  doctest ExRTMP.AMF0

  alias ExRTMP.AMF0

  @payload <<2, 0, 7, 99, 111, 110, 110, 101, 99, 116, 0, 63, 240, 0, 0, 0, 0, 0, 0, 3, 0, 3, 97,
             112, 112, 2, 0, 9, 108, 105, 118, 101, 47, 116, 101, 115, 116, 0, 4, 116, 121, 112,
             101, 2, 0, 10, 110, 111, 110, 112, 114, 105, 118, 97, 116, 101, 0, 8, 102, 108, 97,
             115, 104, 86, 101, 114, 2, 0, 36, 70, 77, 76, 69, 47, 51, 46, 48, 32, 40, 99, 111,
             109, 112, 97, 116, 105, 98, 108, 101, 59, 32, 76, 97, 118, 102, 53, 56, 46, 50, 57,
             46, 49, 48, 48, 41, 0, 5, 116, 99, 85, 114, 108, 2, 0, 31, 114, 116, 109, 112, 58,
             47, 47, 49, 50, 55, 46, 48, 46, 48, 46, 49, 58, 49, 57, 51, 53, 47, 108, 105, 118,
             101, 47, 116, 101, 115, 116, 0, 0, 9>>

  test "Parse command" do
    assert [
             "connect",
             1,
             %{
               "app" => "live/test",
               "flashVer" => "FMLE/3.0 (compatible; Lavf58.29.100)",
               "tcUrl" => "rtmp://127.0.0.1:1935/live/test",
               "type" => "nonprivate"
             }
           ] == AMF0.parse(@payload)
  end

  test "Parse list" do
    payload =
      <<8, 0, 0, 0, 2, 0, 8, 100, 117, 114, 97, 116, 105, 111, 110, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        5, 119, 105, 100, 116, 104, 0, 64, 158, 0, 0, 0, 0, 0, 0, 0, 0, 9>>

    assert [%{"duration" => 0.0, "width" => 1920.0}] == AMF0.parse(payload)
  end

  test "serialize" do
    expected = [
      "connect",
      1,
      %{
        "app" => "live/test",
        "flashVer" => "FMLE/3.0 (compatible; Lavf58.29.100)",
        "tcUrl" => "rtmp://127.0.0.1:1935/live/test",
        "type" => "nonprivate"
      }
    ]

    assert [AMF0.serialize("connect"), AMF0.serialize(1), AMF0.serialize(Enum.at(expected, 2))]
           |> IO.iodata_to_binary()
           |> AMF0.parse() == expected
  end
end
