defmodule Kernel.CLI do
  @moduledoc false

  @blank_config %{commands: [], output: ".", compile: [],
                  halt: true, compiler_options: [], errors: [],
                  verbose_compile: false}

  @doc """
  This is the API invoked by Elixir boot process.
  """
  def main(argv) do
    argv = for arg <- argv, do: IO.chardata_to_string(arg)

    {config, argv} = parse_argv(argv)
    System.argv(argv)

    run fn ->
      errors = process_commands(config)

      if errors != [] do
        Enum.each(errors, &IO.puts(:stderr, &1))
        System.halt(1)
      end
    end, config.halt
  end

  @doc """
  Runs the given function by catching any failure
  and printing them to stdout. `at_exit` hooks are
  also invoked before exiting.

  This function is used by Elixir's CLI and also
  by escripts generated by Elixir.
  """
  def run(fun, halt \\ true) do
    try do
      fun.()
      if halt do
        at_exit(0)
        System.halt(0)
      end
    catch
      :exit, reason when is_integer(reason) ->
        at_exit(reason)
        System.halt(reason)
      :exit, :normal ->
        at_exit(0)
        System.halt(0)
      kind, reason ->
        at_exit(1)
        print_error(kind, reason, System.stacktrace)
        System.halt(1)
    end
  end

  @doc """
  Parses ARGV returning the CLI config and trailing args.
  """
  def parse_argv(argv) do
    parse_argv(argv, @blank_config)
  end

  @doc """
  Process commands according to the parsed config from `parse_argv/1`.
  Returns all errors.
  """
  def process_commands(config) do
    results = Enum.map(Enum.reverse(config.commands), &process_command(&1, config))
    errors  = for {:error, msg} <- results, do: msg
    Enum.reverse(config.errors, errors)
  end

  ## Helpers

  defp at_exit(status) do
    hooks = :elixir_code_server.call(:flush_at_exit)

    for hook <- hooks do
      try do
        hook.(status)
      catch
        kind, reason ->
          print_error(kind, reason, System.stacktrace)
      end
    end

    # If an at_exit callback adds a
    # new hook we need to invoke it.
    unless hooks == [], do: at_exit(status)
  end

  defp shared_option?(list, config, callback) do
    case parse_shared(list, config) do
      {[h|hs], _} when h == hd(list) ->
        new_config = %{config | errors: ["#{h} : Unknown option" | config.errors]}
        callback.(hs, new_config)
      {new_list, new_config} ->
        callback.(new_list, new_config)
    end
  end

  defp print_error(kind, reason, trace) do
    IO.puts :stderr, Exception.format(kind, reason, prune_stacktrace(trace))
  end

  @elixir_internals [:elixir_compiler, :elixir_module, :elixir_translator, :elixir_expand]

  defp prune_stacktrace([{mod, _, _, _}|t]) when mod in @elixir_internals do
    prune_stacktrace(t)
  end

  defp prune_stacktrace([{__MODULE__, :wrapper, 1, _}|_]) do
    []
  end

  defp prune_stacktrace([h|t]) do
    [h|prune_stacktrace(t)]
  end

  defp prune_stacktrace([]) do
    []
  end

  # Parse shared options

  defp parse_shared([opt|_t], _config) when opt in ["-v", "--version"] do
    IO.puts "Elixir #{System.version}"
    System.halt 0
  end

  defp parse_shared(["-pa", h|t], config) do
    add_code_path(h, &Code.prepend_path/1)
    parse_shared t, config
  end

  defp parse_shared(["-pz", h|t], config) do
    add_code_path(h, &Code.append_path/1)
    parse_shared t, config
  end

  defp parse_shared(["--app", h|t], config) do
    parse_shared t, %{config | commands: [{:app, h} | config.commands]}
  end

  defp parse_shared(["--no-halt"|t], config) do
    parse_shared t, %{config | halt: false}
  end

  defp parse_shared(["-e", h|t], config) do
    parse_shared t, %{config | commands: [{:eval, h} | config.commands]}
  end

  defp parse_shared(["-r", h|t], config) do
    parse_shared t, %{config | commands: [{:require, h} | config.commands]}
  end

  defp parse_shared(["-pr", h|t], config) do
    parse_shared t, %{config | commands: [{:parallel_require, h} | config.commands]}
  end

  defp parse_shared([erl, _|t], config) when erl in ["--erl", "--sname", "--name", "--cookie"] do
    parse_shared t, config
  end

  defp parse_shared([erl|t], config) when erl in ["--detached", "--hidden", "--gen-debug"] do
    parse_shared t, config
  end

  defp parse_shared(list, config) do
    {list, config}
  end


  defp add_code_path(path, fun) do
    path = Path.expand(path)
    case Path.wildcard(path) do
      []   -> fun.(path)
      list -> Enum.each(list, fun)
    end
  end

  # Process init options

  defp parse_argv(["--"|t], config) do
    {config, t}
  end

  defp parse_argv(["+elixirc"|t], config) do
    parse_compiler t, config
  end

  defp parse_argv(["+iex"|t], config) do
    parse_iex t, config
  end

  defp parse_argv(["-S", h|t], config) do
    {%{config | commands: [{:script, h} | config.commands]}, t}
  end

  defp parse_argv([h|t] = list, config) do
    case h do
      "-" <> _ ->
        shared_option? list, config, &parse_argv(&1, &2)
      _ ->
        if Keyword.has_key?(config.commands, :eval) do
          {config, list}
        else
          {%{config | commands: [{:file, h} | config.commands]}, t}
        end
    end
  end

  defp parse_argv([], config) do
    {config, []}
  end

  # Parse compiler options

  defp parse_compiler(["--"|t], config) do
    {config, t}
  end

  defp parse_compiler(["-o", h|t], config) do
    parse_compiler t, %{config | output: h}
  end

  defp parse_compiler(["--no-docs"|t], config) do
    parse_compiler t, %{config | compiler_options: [{:docs, false} | config.compiler_options]}
  end

  defp parse_compiler(["--no-debug-info"|t], config) do
    parse_compiler t, %{config | compiler_options: [{:debug_info, false} | config.compiler_options]}
  end

  defp parse_compiler(["--ignore-module-conflict"|t], config) do
    parse_compiler t, %{config | compiler_options: [{:ignore_module_conflict, true} | config.compiler_options]}
  end

  defp parse_compiler(["--warnings-as-errors"|t], config) do
    parse_compiler t, %{config | compiler_options: [{:warnings_as_errors, true} | config.compiler_options]}
  end

  defp parse_compiler(["--verbose"|t], config) do
    parse_compiler t, %{config | verbose_compile: true}
  end

  defp parse_compiler([h|t] = list, config) do
    case h do
      "-" <> _ ->
        shared_option? list, config, &parse_compiler(&1, &2)
      _ ->
        pattern = if :filelib.is_dir(h), do: "#{h}/**/*.ex", else: h
        parse_compiler t, %{config | compile: [pattern | config.compile]}
    end
  end

  defp parse_compiler([], config) do
    {%{config | commands: [{:compile, config.compile}|config.commands]}, []}
  end

  # Parse iex options

  defp parse_iex(["--"|t], config) do
    {config, t}
  end

  # This clause is here so that Kernel.CLI does not
  # error out with "unknown option"
  defp parse_iex(["--dot-iex", _|t], config) do
    parse_iex t, config
  end

  defp parse_iex([opt, _|t], config) when opt in ["--remsh"] do
    parse_iex t, config
  end

  defp parse_iex(["-S", h|t], config) do
    {%{config | commands: [{:script, h} | config.commands]}, t}
  end

  defp parse_iex([h|t] = list, config) do
    case h do
      "-" <> _ ->
        shared_option? list, config, &parse_iex(&1, &2)
      _ ->
        {%{config | commands: [{:file, h} | config.commands]}, t}
    end
  end

  defp parse_iex([], config) do
    {config, []}
  end

  # Process commands

  defp process_command({:cookie, h}, _config) do
    if Node.alive? do
      wrapper fn -> Node.set_cookie(String.to_atom(h)) end
    else
      {:error, "--cookie : Cannot set cookie if the node is not alive (set --name or --sname)"}
    end
  end

  defp process_command({:eval, expr}, _config) when is_binary(expr) do
    wrapper fn -> Code.eval_string(expr, []) end
  end

  defp process_command({:app, app}, _config) when is_binary(app) do
    case Application.ensure_all_started(String.to_atom(app)) do
      {:error, {app, reason}} ->
        {:error, "--app : Could not start application #{app}: " <>
          Application.format_error(reason)}
      {:ok, _} ->
        :ok
    end
  end

  defp process_command({:script, file}, _config) when is_binary(file) do
    if exec = find_elixir_executable(file) do
      wrapper fn -> Code.require_file(exec) end
    else
      {:error, "-S : Could not find executable #{file}"}
    end
  end

  defp process_command({:file, file}, _config) when is_binary(file) do
    if :filelib.is_regular(file) do
      wrapper fn -> Code.require_file(file) end
    else
      {:error, "No file named #{file}"}
    end
  end

  defp process_command({:require, pattern}, _config) when is_binary(pattern) do
    files = filter_patterns(pattern)

    if files != [] do
      wrapper fn -> Enum.map files, &Code.require_file(&1) end
    else
      {:error, "-r : No files matched pattern #{pattern}"}
    end
  end

  defp process_command({:parallel_require, pattern}, _config) when is_binary(pattern) do
    files = filter_patterns(pattern)

    if files != [] do
      wrapper fn -> Kernel.ParallelRequire.files(files) end
    else
      {:error, "-pr : No files matched pattern #{pattern}"}
    end
  end

  defp process_command({:compile, patterns}, config) do
    :filelib.ensure_dir(:filename.join(config.output, "."))

    case filter_multiple_patterns(patterns) do
      {:ok, []} ->
        {:error, "No files matched provided patterns"}
      {:ok, files} ->
        wrapper fn ->
          Code.compiler_options(config.compiler_options)
          Kernel.ParallelCompiler.files_to_path(files, config.output,
            each_file: fn file -> if config.verbose_compile do IO.puts "Compiled #{file}" end end)
        end
      {:missing, missing} ->
        {:error, "No files matched pattern(s) #{Enum.join(missing, ",")}"}
    end
  end

  defp filter_patterns(pattern) do
    Enum.filter(Enum.uniq(Path.wildcard(pattern)), &:filelib.is_regular(&1))
  end

  defp filter_multiple_patterns(patterns) do
    matched_files = Enum.map patterns, fn(pattern) ->
      case filter_patterns(pattern) do
        []    -> {:missing, pattern}
        files -> {:ok, files}
      end
    end

    files = Enum.filter_map matched_files,
       fn(match) -> elem(match, 0) == :ok end,
       &elem(&1, 1)

    missing_patterns = Enum.filter_map matched_files,
       fn(match) -> elem(match, 0) == :missing end,
       &elem(&1, 1)

    if missing_patterns == [] do
      {:ok, Enum.uniq(Enum.concat(files))}
    else
      {:missing,  Enum.uniq(missing_patterns)}
    end
  end

  defp wrapper(fun) do
    fun.()
    :ok
  end

  defp find_elixir_executable(file) do
    if exec = System.find_executable(file) do
      # If we are on Windows, the executable is going to be
      # a .bat file that must be in the same directory as
      # the actual Elixir executable.
      case :os.type() do
        {:win32, _} ->
          exec = Path.rootname(exec)
          if File.regular?(exec), do: exec
        _ ->
          exec
      end
    end
  end
end
