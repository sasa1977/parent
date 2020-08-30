defmodule BufferBatching.Consumer do
  use Parent.GenServer
  alias BufferBatching.{Buffer, Config}

  def start_link(_arg), do: Parent.GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def add(item), do: GenServer.call(__MODULE__, {:add, item})

  @impl GenServer
  def init(nil), do: {:ok, Buffer.new()}

  @impl GenServer
  def handle_call({:add, item}, _from, buffer),
    do: {:reply, :ok, buffer |> Buffer.add(item) |> maybe_process()}

  @impl Parent.GenServer
  def handle_child_terminated(_id, _meta, _pid, _reason, buffer),
    do: {:noreply, maybe_process(buffer)}

  defp maybe_process(buffer) do
    if not Enum.empty?(buffer) and (idle?() or buffer_full?(buffer)),
      do: start_processor(buffer),
      else: buffer
  end

  defp idle?(), do: Parent.num_children() == 0
  defp buffer_full?(buffer), do: Enum.count(buffer) >= Config.max_buffer_size()

  defp start_processor(buffer) do
    Parent.start_child(%{
      id: make_ref(),
      start: {Task, :start_link, [fn -> process_buffer(buffer) end]}
    })

    Buffer.new()
  end

  defp process_buffer(buffer) do
    IO.puts("processing #{Enum.count(buffer)} items")
    Process.sleep(Config.consume_time())
  end
end
