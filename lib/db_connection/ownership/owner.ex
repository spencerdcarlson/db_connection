defmodule DBConnection.Ownership.Owner do
  @moduledoc false

  use GenServer
  @pool_timeout 5_000
  @timeout      15_000

  def start_link(manager, from, pool, pool_opts) do
    GenServer.start_link(__MODULE__, {manager, from, pool, pool_opts}, [])
  end

  def checkout(pool, opts) do
    pool_timeout = opts[:pool_timeout] || @pool_timeout
    queue?       = Keyword.get(opts, :queue, true)
    timeout      = opts[:timeout] || @timeout

    ref = make_ref()
    try do
      GenServer.call(pool, {:checkout, ref, queue?, timeout}, pool_timeout)
    catch
      :exit, {_, {_, :call, [pool | _]}} = reason ->
        GenServer.cast(pool, {:cancel, ref})
        exit(reason)
    end
  end

  def checkin({owner, ref}, state, _opts) do
    GenServer.cast(owner, {:checkin, ref, state})
  end

  def disconnect({owner, ref}, exception, state, _opts) do
    GenServer.cast(owner, {:disconnect, ref, exception, state})
  end

  def stop({owner, ref}, reason, state, _opts) do
    GenServer.cast(owner, {:stop, ref, reason, state})
  end

  def stop(owner) do
    GenServer.cast(owner, :stop)
  end

  # Callbacks

  def init({manager, _, _, _} = args) do
    Process.link(manager)
    send self(), :init
    {:ok, args}
  end

  def handle_info(:init, {manager, from, pool, pool_opts}) do
    pool_mod = Keyword.get(pool_opts, :ownership_pool, DBConnection.Poolboy)

    state = %{client: nil, timer: nil, conn_state: nil, conn_module: nil,
              owner_ref: nil, pool: pool, pool_mod: pool_mod,
              pool_opts: pool_opts, pool_ref: nil, queue: :queue.new}

    try do
      pool_mod.checkout(pool, pool_opts)
    catch
      kind, reason ->
        GenServer.reply(from, {kind, reason, System.stacktrace})
        {:stop, {:shutdown, "no checkout"}, state}
    else
      {:ok, pool_ref, conn_module, conn_state} ->
        GenServer.reply(from, {:ok, self()})
        {caller, _} = from
        ref = Process.monitor(caller)
        {:noreply, %{state | conn_state: conn_state, conn_module: conn_module,
                             owner_ref: ref, pool_ref: pool_ref}}
      :error ->
        GenServer.reply(from, :error)
        {:stop, {:shutdown, "no checkout"}, state}
    after
      Process.unlink(manager)
    end
  end

  def handle_info({:DOWN, mon, _, _, _}, %{client: {_, mon}} = state) do
    disconnect("client down", state)
  end

  def handle_info({:DOWN, ref, _, _, _}, %{owner_ref: ref} = state) do
    down("owner down", state)
  end

  def handle_info({:timeout, timer, __MODULE__}, %{timer: timer} = state) do
    disconnect("client timeout", state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_call({:checkout, ref, queue?, timeout}, from, %{queue: queue} = state) do
    if queue? or :queue.is_empty(queue) do
      {pid, _} = from
      client = {ref, Process.monitor(pid)}
      queue = :queue.in({client, timeout, from}, queue)
      {:noreply, next(queue, state)}
    else
      {:reply, :error, state}
    end
  end

  def handle_cast({:checkin, ref, conn_state}, %{client: {ref, mon}} = state) do
    %{queue: queue} = state
    Process.demonitor(mon, [:flush])
    {:noreply, next(:queue.drop(queue), %{state | conn_state: conn_state})}
  end

  def handle_cast({:checkin, _, _}, state) do
    {:noreply, state}
  end

  def handle_cast({tag, ref, error, conn_state}, %{client: {ref, _}} = state)
  when tag in [:stop, :disconnect] do
    %{pool_mod: pool_mod, pool_ref: pool_ref, pool_opts: pool_opts} = state
    apply(pool_mod, tag, [pool_ref, error, conn_state, pool_opts])
    {:stop, {:shutdown, tag}, state}
  end

  def handle_cast({tag, _, _, _}, state) when tag in [:disconnect, :stop] do
    {:noreply, state}
  end

  def handle_cast({:cancel, ref}, %{client: {ref, mon}} = state) do
    %{queue: queue} = state
    Process.demonitor(mon, [:flush])
    {:noreply, next(:queue.drop(queue), state)}
  end
  def handle_cast({:cancel, ref}, %{queue: queue} = state) do
    cancel =
      fn({{ref2, mon}, _}) ->
        if ref === ref2 do
          Process.demonitor(mon, [:flush])
          false
        else
          true
        end
      end
    {:noreply, %{state | queue: :queue.filter(cancel, queue)}}
  end

  def handle_cast(:stop, state) do
    down("owner checkin", state)
  end

  defp next(queue, %{timer: timer} = state) do
    cancel_timer(timer)
    case :queue.peek(queue) do
      {:value, {{ref, _} = client, timeout, from}} ->
        {caller, _} = from
        %{conn_module: conn_module, conn_state: conn_state} = state
        GenServer.reply(from, {:ok, {self(), ref}, conn_module, conn_state})
        %{state | queue: queue, client: client, timer: start_timer(timeout)}
      :empty ->
        %{state | queue: queue, client: nil, timer: nil}
    end
  end

  defp start_timer(:infinity), do: nil
  defp start_timer(timeout), do: :erlang.start_timer(timeout, self, __MODULE__)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer) do
    case :erlang.cancel_timer(timer) do
      false -> flush_timer(timer)
      _     -> :ok
    end
  end

  defp flush_timer(timer) do
    receive do
      {:timeout, ^timer, __MODULE__} ->
        :ok
    after
      0 ->
        raise ArgumentError, "timer #{inspect(timer)} does not exist"
    end
  end

  # If it is down but it has no client, checkin
  defp down(reason, %{client: nil} = state) do
    %{pool_mod: pool_mod, pool_ref: pool_ref,
      conn_state: conn_state, pool_opts: pool_opts} = state
    pool_mod.checkin(pool_ref, conn_state, pool_opts)
    {:stop, {:shutdown, reason}, state}
  end

  # If it is down but it has a client, disconnect
  defp down(reason, state) do
    %{pool_mod: pool_mod, pool_ref: pool_ref,
      conn_state: conn_state, pool_opts: pool_opts} = state
    error = DBConnection.Error.exception(reason)
    pool_mod.disconnect(pool_ref, error, conn_state, pool_opts)
    {:stop, {:shutdown, reason}, state}
  end

  defp disconnect(reason, state) do
    %{conn_state: conn_state, pool_mod: pool_mod,
      pool_opts: pool_opts, pool_ref: pool_ref} = state
    error = DBConnection.Error.exception(reason)
    pool_mod.disconnect(pool_ref, error, conn_state, pool_opts)
    {:stop, {:shutdown, reason}, state}
  end
end
