defmodule Mox.GlobalServer do
  @moduledoc false

  use GenServer
  @timeout 30000

  # Public API

  def start_link(_options) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def add_expectation(owner_pid, key, value) do
    GenServer.call(__MODULE__, {:add_expectation, owner_pid, key, value}, @timeout)
  end

  def fetch_fun_to_dispatch(_caller_pid, key) do
    GenServer.call(__MODULE__, {:fetch_fun_to_dispatch, key}, @timeout)
  end

  def verify(_owner_pid, for) do
    GenServer.call(__MODULE__, {:verify, for}, @timeout)
  end

  def verify_on_exit(pid) do
    GenServer.call(__MODULE__, {:verify_on_exit, pid}, @timeout)
  end

  def allow(mock, _owner_pid, _pid) do
  end

  def exit(pid) do
    GenServer.cast(__MODULE__, {:exit, pid})
  end

  # Callbacks

  def init(:ok) do
    {:ok, %{expectations: %{}, owner_pid: nil}}
  end

  def handle_call({:add_expectation, owner_pid, {mock, _, _} = key, expectation}, _from, state) do
    state =
      update_in(state, [:expectations], fn expectations ->
        Map.update(expectations, key, expectation, &merge_expectation(&1, expectation))
      end)

    state = Map.put(state, :owner_pid, owner_pid)

    {:reply, :ok, state}
  end

  def handle_call({:fetch_fun_to_dispatch, {mock, _, _} = key}, _from, state) do
    case state.expectations[key] do
      nil ->
        {:reply, :no_expectation, state}

      {total, [], nil} ->
        {:reply, {:out_of_expectations, total}, state}

      {_, [], stub} ->
        {:reply, {:ok, stub}, state}

      {total, [call | calls], stub} ->
        new_state = put_in(state.expectations[key], {total, calls, stub})
        {:reply, {:ok, call}, new_state}
    end
  end

  def handle_call({:verify, mock}, _from, state) do
    pending =
      for {{module, _, _} = key, {count, [_ | _] = calls, _stub}} <- state.expectations,
          module == mock or mock == :all do
        {key, count, length(calls)}
      end

    {:reply, pending, state}
  end



  #def handle_cast({:exit, pid}, state) do
  #  {:noreply, down(state, pid)}
  #end

  #def handle_info({:DOWN, _, _, pid, _}, state) do
    #  case state.deps do
      #     %{^pid => {:DOWN, _}} -> {:noreply, down(state, pid)}
      # %{} -> {:noreply, state}
      # end
      #  end

  # Helper functions

  defp merge_expectation({current_n, current_calls, current_stub}, {n, calls, stub}) do
    {current_n + n, current_calls ++ calls, stub || current_stub}
  end
end
