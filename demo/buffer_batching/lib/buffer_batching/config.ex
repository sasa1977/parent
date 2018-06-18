defmodule BufferBatching.Config do
  def produce_time(), do: Application.get_env(:buffer_batching, :produce_time, 200)
  def consume_time(), do: Application.get_env(:buffer_batching, :consume_time, 100)
  def max_buffer_size(), do: Application.get_env(:buffer_batching, :max_buffer_size, 10)

  def produce_time(value), do: Application.put_env(:buffer_batching, :produce_time, value)
  def consume_time(value), do: Application.put_env(:buffer_batching, :consume_time, value)
  def max_buffer_size(value), do: Application.put_env(:buffer_batching, :max_buffer_size, value)
end
