# ExRTMP

[![Hex.pm](https://img.shields.io/hexpm/v/ex_rtmp.svg)](https://hex.pm/packages/ex_rtmp)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/ex_rtmp)

RTMP server and client library for Elixir.

## Installation

The package can be installed by adding `ex_rtmp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_rtmp, "~> 0.2.0"}
  ]
end
```

## Usage
See the [examples](./examples) folder.

### `save_to_flv.exs`
A client publish to an RTMP server and the server stores into flv file.

To publish a stream to the server use `ffmpeg`:
```bash
ffmpeg -re -i input_file.mp4 -c:v copy -c:a copy -f flv rtmp://localhost:1935/live/test
```

### `send_mp4.exs`
The server stream an mp4 file to connected clients. The mp4 file must have AAC audio and H264/AVC video.

To start the server:
```bash
elixir examples/send_mp4.exs "input_file.mp4"
```

and to play the stream, you can use `vlc` or `ffplay`:
```bash
ffplay -i rtmp://localhost:1935/live/test
```

### `read_to_flv.exs`
A client connects to an RTMP server and saves the stream into an flv file.
```elixir
elixir examples/read_to_flv.exs "rtmp://localhost:1935/live" test output.flv
```
