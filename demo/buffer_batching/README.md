# BufferBatching

This project demonstrates a simple buffering/batching consumer. Normally, you can implement this with GenStage. Parent doesn't aim to compete with GenStage, but in some simple cases, it can serve as a more lightweight solution.

In this demo, we have a consumer which buffers requests and handles them in batches. In this way the consumer tries to profit from the fact that handling N items is much faster than N times handling of a single item. A typical example is inserting into database, where batch inserting usually works much faster than inserting rows one by one.

The example consumer is implemented in `BufferBatching.Consumer` with the helper buffer structure in `BufferBatching.Buffer`. The consumer is adaptive to the load. This means that if the producer is slower than the consumer, the consumer handles items one by one without any delay (since there's no need to batch). However, if the producer is faster, the consumer will adaptively increase the batch size to compensate.

In addition, this consumer implementation tries to leverage concurrency if the producer is much faster than the consumer. This is controlled via the max buffer size setting. If the max buffer size is reached, the consumer starts the processing job, and collects more input. If the producer is much faster, we might end up with multiple concurrent consumer jobs.

Here's how you can verify this. Start the system with `iex -S mix`. Initially, the system starts with the following settings:

- time to produce a single item: 200ms
- time to consume a single item: 100ms
- max buffer size: 10 items

So initially, the producer is much faster than the consumer. Therefore, there's no need for buffering, and the consumer processes items as they arrive, without any delay:

```
processing 1 items
processing 1 items
...
```

Now, let's make the consumer slower:

```elixir
iex> BufferBatching.Config.consume_time(:timer.seconds(1))

processing 1 items
processing 4 items
processing 5 items
processing 5 items
...
```

As you can see, the consumer adapted to the load, and it's now processing five items at the time.

Next, let's see the adaptive concurrency. We'll make the producer much faster:

```elixir
iex> BufferBatching.Config.produce_time(50)

processing 10 items
...
```

The consumer is handling 10 items at once. However, the producer is producing 20 items per second, and consumer delay is one second. Therefore, the consumer increased the concurrency to accommodate the load. You can see this if you fire up the observer and head to the applications tab. Under the `Elixir.BufferBatching.Consumer`, you'll find two processes, which are two concurrent consumer workers, each handling its own batch of 10 jobs. If you e.g. make the consumer slower, you'll see that the worker pool increases:

```elixir
BufferBatching.Config.consume_time(:timer.seconds(2))
```

Likewise, if you make the consumer much faster, the batch will decrease, and only one worker will be used:

```elixir
BufferBatching.Config.consume_time(1)
```

Finally, it's worth mentioning that each batch is handled in its own short living process. I.e. there is no fixed pool of processes.
