defmodule Mox do
  @moduledoc """
  Mox is a library for defining concurrent mocks in Elixir.

  The library follows the principles outlined in
  ["Mocks and explicit contracts"](http://blog.plataformatec.com.br/2015/10/mocks-and-explicit-contracts/),
  summarized below:

    1. No ad-hoc mocks. You can only create mocks based on behaviours

    2. No dynamic generation of modules during tests. Mocks are preferably defined
       in your `test_helper.exs` or in a `setup_all` block and not per test

    3. Concurrency support. Tests using the same mock can still use `async: true`

    4. Rely on pattern matching and function clauses for asserting on the
       input instead of complex expectation rules

  ## Example

  As an example, imagine that your library defines a calculator behaviour:

      defmodule MyApp.Calculator do
        @callback add(integer(), integer()) :: integer()
        @callback mult(integer(), integer()) :: integer()
      end

  If you want to mock the calculator behaviour during tests, the first step
  is to define the mock, usually in your `test_helper.exs`:

      Mox.defmock(MyApp.CalcMock, for: MyApp.Calculator)

  Once the mock is defined, you can pass it to the system under the test.
  If the system under test relies on application configuration, you should
  also set it before the tests starts to keep the async property. Usually
  in your config files:

      config :my_app, :calculator, MyApp.CalcMock

  Or in your `test_helper.exs`:

      Application.put_env(:my_app, :calculator, MyApp.CalcMock)

  Now in your tests, you can define expectations and verify them:

      use ExUnit.Case, async: true

      import Mox

      # Make sure mocks are verified when the test exits
      setup :verify_on_exit!

      test "invokes add and mult" do
        MyApp.CalcMock
        |> expect(:add, fn x, y -> x + y end)
        |> expect(:mult, fn x, y -> x * y end)

        assert MyApp.CalcMock.add(2, 3) == 5
        assert MyApp.CalcMock.mult(2, 3) == 6
      end

  All expectations are defined based on the current process. This
  means multiple tests using the same mock can still run concurrently.

  ## Compile-time requirements

  If the mock needs to be available during the project compilation, for
  instance because you get undefined function warnings, then instead of
  defining the mock in your `test_helper.exs`, you should instead define
  it under `test/support/mocks.ex`:

      Mox.defmock(MyApp.CalcMock, for: MyApp.Calculator)

  Then you need to make sure that files in `test/support` get compiled
  with the rest of the project. Edit your `mix.exs` file to add `test/support`
  directory to compilation paths:

      def project do
        [
          ...
          elixirc_paths: elixirc_paths(Mix.env),
          ...
        ]
      end

      defp elixirc_paths(:test), do: ["test/support", "lib"]
      defp elixirc_paths(_),     do: ["lib"]

  ## Multi-process collaboration

  Mox supports multi-process collaboration via an explicit allowances
  where a child process is allowed to use the expectations and stubs
  defined in the parent process while still being safe for async tests.

      test "invokes add and mult from a task" do
        MyApp.CalcMock
        |> expect(:add, fn x, y -> x + y end)
        |> expect(:mult, fn x, y -> x * y end)

        parent_pid = self()

        Task.async(fn ->
          MyApp.CalcMock |> allow(parent_pid, self())
          assert MyApp.CalcMock.add(2, 3) == 5
          assert MyApp.CalcMock.mult(2, 3) == 6
        end)
        |> Task.await
      end

  """

  defmodule UnexpectedCallError do
    defexception [:message]
  end

  defmodule VerificationError do
    defexception [:message]
  end

  @doc """
  Sets the work mode to either :private or :global.

      Mox.set_mode(:private)

  """
  def set_mode(:private), do: Application.put_env(:mox, :mode, :private)
  def set_mode(:global), do: Application.put_env(:mox, :mode, :global)
  def set_mode(unknown_mode), do: raise ArgumentError, "Unknown mode: #{unknown_mode}. Use either :global or :private."

  @doc """
  Defines a mock with the given name `:for` the given behaviour.

      Mox.defmock MyMock, for: MyBehaviour

  """
  def defmock(name, options) when is_atom(name) and is_list(options) do
    behaviour = options[:for] || raise ArgumentError, ":for option is required on defmock"
    validate_behaviour!(behaviour)
    define_mock_module(name, behaviour)
    name
  end

  defp validate_behaviour!(behaviour) do
    cond do
      not Code.ensure_compiled?(behaviour) ->
        raise ArgumentError,
              "module #{inspect behaviour} is not available, please pass an existing module to :for"

      not function_exported?(behaviour, :behaviour_info, 1) ->
        raise ArgumentError,
              "module #{inspect behaviour} is not a behaviour, please pass a behaviour to :for"

      true ->
        :ok
    end
  end

  defp define_mock_module(name, behaviour) do
    funs =
      for {fun, arity} <- behaviour.behaviour_info(:callbacks) do
        args = 0..arity |> Enum.to_list |> tl() |> Enum.map(&Macro.var(:"arg#{&1}", Elixir))
        quote do
          def unquote(fun)(unquote_splicing(args)) do
            Mox.__dispatch__(__MODULE__, unquote(fun), unquote(arity), unquote(args))
          end
        end
      end

    info =
      quote do
        def __mock_for__ do
          unquote(behaviour)
        end
      end

    Module.create(name, [info | funs], Macro.Env.location(__ENV__))
  end

  @doc """
  Defines that the `name` in `mock` with arity given by
  `code` will be invoked `n` times.

  ## Examples

  To allow `MyMock.add/2` to be called once:

      expect(MyMock, :add, fn x, y -> x + y end)

  To allow `MyMock.add/2` to be called five times:

      expect(MyMock, :add, 5, fn x, y -> x + y end)

  `expect/4` can also be invoked multiple times for the same
  name/arity, allowing you to give different behaviours on each
  invocation.
  """
  def expect(mock, name, n \\ 1, code)
      when is_atom(mock) and is_atom(name) and is_integer(n) and n >= 1 and is_function(code) do
    calls = List.duplicate(code, n)
    add_expectation!(mock, name, code, {n, calls, nil})
    mock
  end

  @doc """
  Defines that the `name` in `mock` with arity given by
  `code` can be invoked zero or many times.

  Opposite to expectations, stubs are never verified.

  If expectations and stubs are defined for the same function
  and arity, the stub is invoked only after all expecations are
  fulfilled.

  ## Examples

  To allow `MyMock.add/2` to be called any number of times:

      stub(MyMock, :add, fn x, y -> x + y end)

  `stub/3` will overwrite any previous calls to `stub/3`.
  """
  def stub(mock, name, code)
      when is_atom(mock) and is_atom(name) and is_function(code) do
    add_expectation!(mock, name, code, {0, [], code})
    mock
  end

  defp add_expectation!(mock, name, code, value) do
    validate_mock!(mock)
    arity = :erlang.fun_info(code)[:arity]
    key = {mock, name, arity}

    unless function_exported?(mock, name, arity) do
      raise ArgumentError, "unknown function #{name}/#{arity} for mock #{inspect mock}"
    end

    case server().add_expectation(self(), key, value) do
      :ok ->
        :ok

      {:error, {:currently_allowed, owner_pid}} ->
        inspected = inspect(self())

        raise ArgumentError, """
        cannot add expectations/stubs to #{inspect mock} in the current process (#{inspected})
        because the process has been allowed by #{inspect owner_pid}.

        Note you cannot mix allowances with expectations/stubs
        """
    end
  end

  @doc """
  Allows other processes to share expectations and stubs
  defined by owner process.

  ## Examples

  To allow `child_pid` to call any stubs or expectations defined for `MyMock`:

      allow(MyMock, self(), child_pid)

  """
  def allow(_mock, owner_pid, allowed_pid) when owner_pid == allowed_pid do
    raise ArgumentError, "owner_pid and allowed_pid must be different"
  end

  def allow(mock, owner_pid, allowed_pid)
      when is_atom(mock) and is_pid(owner_pid) and is_pid(allowed_pid) do
    case server().allow(mock, owner_pid, allowed_pid) do
      :ok ->
        mock

      {:error, {:already_allowed, actual_pid}} ->
        raise ArgumentError, """
        cannot allow #{inspect allowed_pid} to use #{inspect mock} from #{inspect owner_pid}
        because it is already allowed by #{inspect actual_pid}.

        If you are seeing this error message, it is because you are either
        setting up allowances from different processes or your tests have
        async: true and you found a race condition where two different tests
        are allowing the same process
        """

      {:error, :expectations_defined} ->
        raise ArgumentError, """
        cannot allow #{inspect allowed_pid} to use #{inspect mock} from #{inspect owner_pid}
        because the process has already defined its own expectations/stubs
        """
    end
  end

  @doc """
  Verifies the current process after it exits.
  """
  def verify_on_exit!(_context \\ %{}) do
    pid = self()
    server().verify_on_exit(pid)
    ExUnit.Callbacks.on_exit(Mox, fn ->
      verify_mock_or_all!(pid, :all)
      server().exit(pid)
    end)
  end

  @doc """
  Verifies that all expectations set by the current process
  have been called.
  """
  def verify! do
    verify_mock_or_all!(self(), :all)
  end

  @doc """
  Verifies that all expectations in `mock` have been called.
  """
  def verify!(mock) do
    validate_mock!(mock)
    verify_mock_or_all!(self(), mock)
  end

  defp verify_mock_or_all!(pid, mock) do
    pending = server().verify(pid, mock)

    messages =
      for {{module, name, arity}, total, pending} <- pending do
        mfa = Exception.format_mfa(module, name, arity)
        called = total - pending
        "  * expected #{mfa} to be invoked #{times(total)} but it was invoked #{times(called)}"
      end

    if messages != [] do
      raise VerificationError, "error while verifying mocks for #{inspect pid}:\n\n" <> Enum.join(messages, "\n")
    end

    :ok
  end

  defp validate_mock!(mock) do
    cond do
      not Code.ensure_compiled?(mock) ->
        raise ArgumentError, "module #{inspect mock} is not available"

      not function_exported?(mock, :__mock_for__, 0) ->
        raise ArgumentError, "module #{inspect mock} is not a mock"

      true ->
        :ok
    end
  end

  @doc false
  def __dispatch__(mock, name, arity, args) do
    case server().fetch_fun_to_dispatch(self(), {mock, name, arity}) do
      :no_expectation ->
        mfa = Exception.format_mfa(mock, name, arity)
        raise UnexpectedCallError, "no expectation defined for #{mfa} in process #{inspect(self())}"

      {:out_of_expectations, count} ->
        mfa = Exception.format_mfa(mock, name, arity)
        raise UnexpectedCallError,
              "expected #{mfa} to be called #{times(count)} but it has been " <>
              "called #{times(count + 1)} in process #{inspect(self())}"

      {:ok, fun_to_call} ->
        apply(fun_to_call, args)
    end
  end

  defp times(1), do: "once"
  defp times(n), do: "#{n} times"

  defp server() do
    case Application.get_env(:mox, :mode) do
      :global ->
        Mox.GlobalServer
      _ ->
        Mox.Server
    end
  end
end
