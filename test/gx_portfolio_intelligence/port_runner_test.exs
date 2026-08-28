defmodule GxPortfolioIntelligence.PortRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GxPortfolioIntelligence.TradingAgents.PortRunner

  setup do
    original = Application.get_env(:gx_portfolio_intelligence, :port_runner)
    root = Path.join(System.tmp_dir!(), "gx-pi-port-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :port_runner, original)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "decodes a bounded JSON-only process contract without a shell", %{root: root} do
    executable = System.find_executable("printf")

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: [~s({"schema_version":"1.0","status":"ok"})],
      timeout_ms: 1_000,
      max_output_bytes: 1_000
    )

    assert {:ok, %{"status" => "ok"}} = PortRunner.execute([])
  end

  test "discards stderr warnings before decoding the final JSON contract", %{root: root} do
    executable = System.find_executable("python3")
    parent = self()

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: [
        "-c",
        "import json,sys; sys.stderr.write('Authorization: Bearer secret-sentinel\\n'); print(json.dumps({'schema_version':1,'status':'partial'}))"
      ],
      timeout_ms: 2_000,
      max_output_bytes: 1_000
    )

    log =
      capture_log(fn ->
        send(parent, {:runner_result, PortRunner.execute([])})
      end)

    assert_receive {:runner_result, {:ok, %{"status" => "partial"}}}
    refute log =~ "secret-sentinel"
  end

  test "normalizes malformed, non-object and schema-less contracts", %{root: root} do
    executable = System.find_executable("printf")

    for {payload, expected_error} <- [
          {"not-json", :invalid_json_contract},
          {"[]", :invalid_json_contract},
          {~s({"status":"ok"}), :missing_schema_version}
        ] do
      Application.put_env(:gx_portfolio_intelligence, :port_runner,
        executable: executable,
        project_root: root,
        artifact_root: root,
        argv_prefix: [payload],
        timeout_ms: 1_000,
        max_output_bytes: 1_000
      )

      assert {:error, ^expected_error} = PortRunner.execute([])
    end
  end

  test "drops command stderr before it can reach Oban or logs", %{root: root} do
    executable = System.find_executable("python3")

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: ["-c", "import sys; sys.stderr.write('Bearer secret-sentinel'); sys.exit(7)"],
      timeout_ms: 2_000,
      max_output_bytes: 1_000
    )

    assert {:error, {:command_failed, 7}} = PortRunner.execute([])
  end

  test "maps a noisy Python durable-claim exit to a retryable typed outcome", %{root: root} do
    executable = System.find_executable("python3")

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: [
        "-c",
        "import json,sys; sys.stderr.write('claim already active\\n'); print(json.dumps({'schema_version':1,'status':'claimed'})); sys.exit(75)"
      ],
      timeout_ms: 2_000,
      max_output_bytes: 1_000
    )

    assert {:error, :research_claimed} = PortRunner.execute([])
  end

  test "enforces a hard wall-clock timeout even when the child emits output", %{root: root} do
    executable = System.find_executable("python3")

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: [
        "-c",
        "import sys,time\nfor _ in range(100):\n sys.stdout.write('x'); sys.stdout.flush(); time.sleep(.02)"
      ],
      timeout_ms: 20,
      max_output_bytes: 10_000
    )

    assert {:error, :timeout} = PortRunner.execute([])
  end

  test "stops a child whose output exceeds the configured bound", %{root: root} do
    executable = System.find_executable("printf")

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: [String.duplicate("x", 101)],
      timeout_ms: 1_000,
      max_output_bytes: 100
    )

    assert {:error, :output_too_large} = PortRunner.execute([])
  end

  test "rejects a symlink component before handing an artifact path to Python", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "gx-pi-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "escape"))

    on_exit(fn -> File.rm_rf!(outside) end)

    assert_raise ArgumentError, "artifact path is outside configured root", fn ->
      PortRunner.status(
        date: ~D[2026-08-21],
        output_root: Path.join(root, "escape")
      )
    end
  end

  test "passes requested tickers and ad-hoc execution identity as argv without a shell", %{
    root: root
  } do
    executable = System.find_executable("python3")

    Application.put_env(:gx_portfolio_intelligence, :port_runner,
      executable: executable,
      project_root: root,
      artifact_root: root,
      argv_prefix: [
        "-c",
        "import json,sys; print(json.dumps({'schema_version':1,'argv':sys.argv[1:]}))"
      ],
      timeout_ms: 2_000,
      max_output_bytes: 10_000
    )

    assert {:ok, %{"argv" => universe_argv}} =
             PortRunner.universe(
               date: ~D[2026-08-24],
               cutoff: ~U[2026-08-24 08:04:00Z],
               slot: "adhoc-7",
               limit: 2,
               price_mode: "historical",
               tickers: ["FPT", "HPG"],
               output: Path.join(root, "universe.json")
             )

    assert argv_values(universe_argv, "--ticker") == ["FPT", "HPG"]
    assert option_value(universe_argv, "--price-mode") == "historical"

    assert {:ok, %{"argv" => run_argv}} =
             PortRunner.run_one(
               ticker: "HPG",
               date: ~D[2026-08-24],
               cutoff: ~U[2026-08-24 08:04:00Z],
               liquidity_rank: 1,
               adtv20: Decimal.new(100),
               adv20: Decimal.new(10),
               universe_fingerprint: String.duplicate("a", 64),
               mode: "adhoc",
               research_mode: "historical",
               execution_key: String.duplicate("b", 64),
               output_root: root
             )

    assert option_value(run_argv, "--mode") == "adhoc"
    assert option_value(run_argv, "--research-mode") == "historical"
    assert option_value(run_argv, "--execution-key") == String.duplicate("b", 64)
  end

  defp argv_values(argv, option) do
    argv
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {^option, index} -> [Enum.at(argv, index + 1)]
      _ -> []
    end)
  end

  defp option_value(argv, option), do: argv |> argv_values(option) |> List.first()
end
