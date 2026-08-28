defmodule GxPortfolioIntelligence.TradingAgents.PortRunner do
  @behaviour GxPortfolioIntelligence.TradingAgents.Runner

  require Logger

  @ticker ~r/^[A-Z0-9][A-Z0-9._-]{0,19}$/
  @lanes ~w(social media macro)
  @orchestrator_only_env ~w(DATABASE_URL SECRET_KEY_BASE GX_PI_API_TOKEN RAG_SERVICE_API_KEY GX_PI_WEBHOOK_TOKEN)

  @impl true
  def universe(opts) do
    args = [
      "daily",
      "universe",
      "--date",
      date!(opts[:date]),
      "--cutoff",
      datetime!(opts[:cutoff]),
      "--slot",
      safe_label!(opts[:slot]),
      "--limit",
      integer!(opts[:limit], 1, 600),
      "--price-mode",
      price_mode!(opts[:price_mode] || "live"),
      "--output",
      artifact_path!(opts[:output])
    ]

    args =
      args ++
        Enum.flat_map(opts[:tickers] || [], fn ticker -> ["--ticker", ticker!(ticker)] end)

    execute(args)
  end

  @impl true
  def collect(opts) do
    lane = to_string(opts[:lane])
    if lane not in @lanes, do: raise(ArgumentError, "invalid collector lane")

    args = [
      "daily",
      "collect",
      "--lane",
      lane,
      "--slot",
      safe_label!(opts[:slot]),
      "--cutoff",
      datetime!(opts[:cutoff]),
      "--tickers-file",
      artifact_path!(opts[:tickers_file]),
      "--output-root",
      artifact_path!(opts[:output_root])
    ]

    execute(args)
  end

  @impl true
  def run_one(opts) do
    args = [
      "daily",
      "run-one",
      "--ticker",
      ticker!(opts[:ticker]),
      "--date",
      date!(opts[:date]),
      "--cutoff",
      datetime!(opts[:cutoff]),
      "--liquidity-rank",
      integer!(opts[:liquidity_rank], 1, 500),
      "--adtv20",
      decimal!(opts[:adtv20]),
      "--adv20",
      decimal!(opts[:adv20]),
      "--universe-fingerprint",
      hash!(opts[:universe_fingerprint]),
      "--mode",
      mode!(opts[:mode] || "eod"),
      "--research-mode",
      research_mode!(opts[:research_mode] || if(opts[:mode] == "adhoc", do: "live", else: "eod")),
      "--output-root",
      artifact_path!(opts[:output_root])
    ]

    args =
      if opts[:execution_key],
        do: args ++ ["--execution-key", hash!(opts[:execution_key])],
        else: args

    execute(args)
  end

  @impl true
  def status(opts) do
    args = [
      "daily",
      "status",
      "--date",
      date!(opts[:date]),
      "--output-root",
      artifact_path!(opts[:output_root])
    ]

    args = if opts[:ticker], do: args ++ ["--ticker", ticker!(opts[:ticker])], else: args
    execute(args)
  end

  @impl true
  def trend(opts) do
    weights = opts[:weights] || %{}

    args = [
      "daily",
      "trend",
      "--date",
      date!(opts[:date]),
      "--cutoff",
      datetime!(opts[:cutoff]),
      "--previous-cutoff",
      datetime!(opts[:previous_cutoff]),
      "--slot",
      safe_label!(opts[:slot]),
      "--universe-manifest",
      artifact_path!(opts[:universe_manifest]),
      "--output",
      artifact_path!(opts[:output]),
      "--weight-volume-ratio",
      decimal!(weights[:volume_ratio] || weights["volume_ratio"]),
      "--weight-daily-move-abs",
      decimal!(weights[:daily_move_abs] || weights["daily_move_abs"]),
      "--weight-momentum20-abs",
      decimal!(weights[:momentum20_abs] || weights["momentum20_abs"]),
      "--weight-social-attention",
      decimal!(weights[:social_attention] || weights["social_attention"]),
      "--weight-media-event",
      decimal!(weights[:media_event] || weights["media_event"])
    ]

    execute(args)
  end

  @impl true
  def analysis_init(opts) do
    args = [
      "analysis",
      "init",
      "--ticker",
      ticker!(opts[:ticker]),
      "--date",
      date!(opts[:date]),
      "--cutoff",
      datetime!(opts[:cutoff]),
      "--research-mode",
      research_mode!(opts[:research_mode]),
      "--data-provenance",
      provenance!(opts[:data_provenance]),
      "--liquidity-rank",
      integer!(opts[:liquidity_rank], 1, 500),
      "--universe-fingerprint",
      sha256!(opts[:universe_fingerprint]),
      "--execution-key",
      sha256!(opts[:execution_key]),
      "--execution-generation",
      integer!(opts[:execution_generation], 1, 1_000_000),
      "--parent-identity-hash",
      sha256!(opts[:parent_identity_hash]),
      "--expected-digest-hash",
      sha256!(opts[:expected_digest_hash]),
      "--output-root",
      artifact_path!(opts[:output_root])
    ]

    execute_full(args)
  end

  @impl true
  def analysis_run_stage(opts) do
    execute_full([
      "analysis",
      "run-stage",
      "--session",
      artifact_path!(opts[:session]),
      "--stage",
      stage!(opts[:stage]),
      "--expected-identity",
      sha256!(opts[:expected_identity])
    ])
  end

  @impl true
  def analysis_export_rag(opts) do
    execute_full(["analysis", "export-rag", "--session", artifact_path!(opts[:session])])
  end

  @impl true
  def analysis_status(opts) do
    execute_full(["analysis", "status", "--session", artifact_path!(opts[:session])])
  end

  def execute(args) when is_list(args) do
    with {:ok, config} <- validate_config(),
         :ok <- validate_args(args),
         {:ok, output} <- run_port(config, config.argv_prefix ++ args),
         {:ok, result} <- decode_contract(output) do
      {:ok, result}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp execute_full(args) when is_list(args) do
    with {:ok, config} <- validate_config(),
         :ok <- validate_args(args),
         {:ok, output} <-
           run_port(config, config.argv_prefix ++ args, config.full_stage_timeout_ms),
         {:ok, result} <- decode_contract(output) do
      {:ok, result}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp validate_config do
    config = Application.get_env(:gx_portfolio_intelligence, :port_runner, [])
    executable = config[:executable]
    root = config[:project_root]
    artifact_root = config[:artifact_root]

    with true <-
           (is_binary(executable) and Path.type(executable) == :absolute) or
             {:error, :invalid_executable},
         {:ok, %{type: :regular}} <- File.stat(executable),
         true <-
           (is_binary(root) and Path.type(root) == :absolute) or {:error, :invalid_project_root},
         {:ok, %{type: :directory}} <- File.stat(root),
         true <-
           (is_binary(artifact_root) and Path.type(artifact_root) == :absolute) or
             {:error, :invalid_artifact_root} do
      {:ok,
       %{
         executable: executable,
         project_root: Path.expand(root),
         artifact_root: Path.expand(artifact_root),
         argv_prefix: config[:argv_prefix] || ["-m", "cli.gx_main"],
         timeout_ms: config[:timeout_ms] || 900_000,
         full_stage_timeout_ms: config[:full_stage_timeout_ms] || 1_800_000,
         max_output_bytes: config[:max_output_bytes] || 2_000_000
       }}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_port_runner_config}
    end
  end

  defp run_port(config, args), do: run_port(config, args, config.timeout_ms)

  defp run_port(config, args, timeout_ms) do
    Logger.info("starting TradingAgents command", command: Enum.take(args, 3))

    child_env =
      [{~c"PYTHONPATH", String.to_charlist(config.project_root)}] ++
        Enum.map(@orchestrator_only_env, &{String.to_charlist(&1), false})

    port =
      Port.open({:spawn_executable, config.executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: config.project_root,
        env: child_env
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_port(port, [], 0, config.max_output_bytes, deadline)
  end

  defp collect_port(port, chunks, size, max_bytes, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        next_size = size + byte_size(data)

        if next_size > max_bytes do
          Port.close(port)
          {:error, :output_too_large}
        else
          collect_port(port, [data | chunks], next_size, max_bytes, deadline)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

        if status == 75 and match?({:ok, %{"status" => "claimed"}}, decode_contract(output)) do
          {:error, :research_claimed}
        else
          # Never return child output to Oban, logs or API errors. Collector
          # output can contain upstream free text even after secret redaction.
          {:error, {:command_failed, status}}
        end
    after
      remaining ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp decode_contract(output) do
    contract =
      output
      |> String.split(["\r\n", "\n", "\r"], trim: true)
      |> List.last()

    with true <- is_binary(contract) or {:error, :invalid_json_contract},
         {:ok, value} when is_map(value) <- Jason.decode(String.trim(contract)),
         true <- Map.has_key?(value, "schema_version") or {:error, :missing_schema_version} do
      {:ok, value}
    else
      {:ok, _} -> {:error, :invalid_json_contract}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json_contract}
      {:error, _} = error -> error
      false -> {:error, :invalid_json_contract}
    end
  end

  defp validate_args(args) do
    if Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>))) do
      :ok
    else
      {:error, :invalid_argument}
    end
  end

  defp ticker!(ticker) do
    ticker = ticker |> to_string() |> String.upcase()
    if Regex.match?(@ticker, ticker), do: ticker, else: raise(ArgumentError, "invalid ticker")
  end

  defp date!(%Date{} = date), do: Date.to_iso8601(date)

  defp date!(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.to_iso8601(parsed)
      _ -> raise ArgumentError, "invalid date"
    end
  end

  defp date!(_), do: raise(ArgumentError, "invalid date")

  defp datetime!(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp datetime!(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed, _} -> DateTime.to_iso8601(parsed)
      _ -> raise ArgumentError, "invalid cutoff"
    end
  end

  defp datetime!(_), do: raise(ArgumentError, "invalid cutoff")

  defp integer!(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: Integer.to_string(value)

  defp integer!(_, _, _), do: raise(ArgumentError, "invalid integer argument")

  defp decimal!(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp decimal!(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> Decimal.to_string(decimal, :normal)
      _ -> raise ArgumentError, "invalid decimal argument"
    end
  end

  defp decimal!(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp decimal!(_), do: raise(ArgumentError, "invalid decimal argument")

  defp hash!(value) when is_binary(value) and byte_size(value) in 32..128 do
    if Regex.match?(~r/^[a-zA-Z0-9:_-]+$/, value),
      do: value,
      else: raise(ArgumentError, "invalid fingerprint")
  end

  defp hash!(_), do: raise(ArgumentError, "invalid fingerprint")

  defp sha256!(value) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, value),
      do: value,
      else: raise(ArgumentError, "invalid sha256")
  end

  defp sha256!(_), do: raise(ArgumentError, "invalid sha256")

  defp safe_label!(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z0-9:_-]{1,32}$/, value),
      do: value,
      else: raise(ArgumentError, "invalid label")
  end

  defp safe_label!(_), do: raise(ArgumentError, "invalid label")

  defp mode!(value) when value in ["eod", "adhoc"], do: value
  defp mode!(_), do: raise(ArgumentError, "invalid research mode")

  defp research_mode!(value) when value in ["eod", "live", "historical"], do: value
  defp research_mode!(_), do: raise(ArgumentError, "invalid research mode")

  defp price_mode!(value) when value in ["live", "historical"], do: value
  defp price_mode!(_), do: raise(ArgumentError, "invalid price mode")

  defp provenance!(value)
       when value in ["eod_cutoff", "request_cutoff", "historical_replay"],
       do: value

  defp provenance!(_), do: raise(ArgumentError, "invalid data provenance")

  defp stage!(value)
       when value in ~w(market sentiment news fundamentals research trader risk),
       do: value

  defp stage!(_), do: raise(ArgumentError, "invalid analysis stage")

  defp artifact_path!(path) when is_binary(path) do
    with {:ok, root} <- GxPortfolioIntelligence.ArtifactStore.root(),
         :ok <- GxPortfolioIntelligence.ArtifactStore.ensure_within(path, root),
         :ok <- GxPortfolioIntelligence.ArtifactStore.ensure_port_path(path) do
      Path.expand(path)
    else
      _ -> raise ArgumentError, "artifact path is outside configured root"
    end
  end

  defp artifact_path!(_), do: raise(ArgumentError, "invalid artifact path")
end
