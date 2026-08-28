defmodule GxPortfolioIntelligence.WorkflowTest do
  use GxPortfolioIntelligence.DataCase, async: false

  import Phoenix.ConnTest

  alias GxPortfolioIntelligence.{Alerts, Orchestrator, Research}

  alias GxPortfolioIntelligence.Schemas.{
    AlertEvent,
    ResearchBatch,
    ResearchBatchRequestKey,
    ResearchItem
  }

  alias GxPortfolioIntelligence.Schemas.{UniverseMember, UniverseSnapshot}

  alias GxPortfolioIntelligence.Workers.{
    AlertWorker,
    EvidenceWorker,
    FanoutWorker,
    RagBatchWorker,
    ResearchWorker,
    SlaWorker
  }

  alias GxPortfolioIntelligence.Workers.UniverseWorker

  @endpoint GxPortfolioIntelligenceWeb.Endpoint

  defmodule CapturingRAGClient do
    @behaviour GxPortfolioIntelligence.RAG.ClientBehaviour

    def put_batch(batch) do
      send(Application.fetch_env!(:gx_portfolio_intelligence, :test_pid), {
        :rag_batch,
        batch.target_count
      })

      {:ok, %{}}
    end

    def put_documents(_batch_id, documents) do
      send(Application.fetch_env!(:gx_portfolio_intelligence, :test_pid), {
        :rag_documents,
        documents
      })

      {:ok, %{"items" => []}}
    end

    def seal(batch_id) do
      send(Application.fetch_env!(:gx_portfolio_intelligence, :test_pid), {:rag_sealed, batch_id})
      {:ok, %{}}
    end

    def status(_batch_id, _opts) do
      {:ok,
       %{
         "items" => Application.get_env(:gx_portfolio_intelligence, :test_rag_items, [])
       }}
    end

    def full_report(_batch_id, _ticker), do: {:error, :not_configured}

    def health, do: {:ok, %{"status" => "ok"}}
  end

  defmodule DegradedUniverseRunner do
    @behaviour GxPortfolioIntelligence.TradingAgents.Runner

    def universe(opts) do
      {:ok,
       %{
         "schema_version" => 1,
         "status" => "degraded",
         "analysis_date" => Date.to_iso8601(opts[:date]),
         "cutoff" => DateTime.to_iso8601(opts[:cutoff]),
         "slot" => opts[:slot],
         "target_count" => opts[:limit],
         "fingerprint" => String.duplicate("f", 64),
         "artifact_path" => opts[:output],
         "members" => [
           %{
             "ticker" => "HPG",
             "exchange" => "HOSE",
             "rank" => 1,
             "adtv20" => "1000000",
             "adv20" => "100000",
             "aliases" => ["Hoa Phat"]
           }
         ]
       }}
    end

    def collect(_opts), do: {:error, :not_configured}
    def run_one(_opts), do: {:error, :not_configured}
    def status(_opts), do: {:error, :not_configured}
  end

  defmodule EvidenceContractRunner do
    @behaviour GxPortfolioIntelligence.TradingAgents.Runner

    def universe(_opts), do: {:error, :not_configured}

    def collect(_opts) do
      {:ok, Application.fetch_env!(:gx_portfolio_intelligence, :test_evidence_result)}
    end

    def run_one(_opts), do: {:error, :not_configured}
    def status(_opts), do: {:error, :not_configured}
  end

  defmodule RolloutUniverseRunner do
    @behaviour GxPortfolioIntelligence.TradingAgents.Runner

    def universe(opts) do
      if pid = Application.get_env(:gx_portfolio_intelligence, :test_pid) do
        send(pid, {:rollout_universe_called, opts})
      end

      members =
        for rank <- 1..opts[:limit] do
          %{
            "ticker" => "R" <> String.pad_leading(Integer.to_string(rank), 3, "0"),
            "exchange" => "HOSE",
            "rank" => rank,
            "adtv20" => Integer.to_string(1_000_000 - rank),
            "adv20" => Integer.to_string(100_000 - rank),
            "aliases" => []
          }
        end

      {:ok,
       %{
         "schema_version" => 1,
         "status" => "complete",
         "analysis_date" => Date.to_iso8601(opts[:date]),
         "cutoff" => DateTime.to_iso8601(opts[:cutoff]),
         "slot" => opts[:slot],
         "target_count" => opts[:limit],
         "fingerprint" => String.duplicate("b", 64),
         "artifact_path" => opts[:output],
         "members" => members
       }}
    end

    def collect(_opts), do: {:error, :not_configured}
    def run_one(_opts), do: {:error, :not_configured}
    def status(_opts), do: {:error, :not_configured}
  end

  defmodule CapturingAlertDispatcher do
    @behaviour GxPortfolioIntelligence.Alerts.Dispatcher

    def deliver(payload) do
      send(
        Application.fetch_env!(:gx_portfolio_intelligence, :test_pid),
        {:alert_payload, payload}
      )

      :ok
    end
  end

  setup do
    original_client = Application.get_env(:gx_portfolio_intelligence, :rag_client)
    Application.put_env(:gx_portfolio_intelligence, :test_pid, self())

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :rag_client, original_client)
      Application.delete_env(:gx_portfolio_intelligence, :test_pid)
      Application.delete_env(:gx_portfolio_intelligence, :test_rag_items)
      Application.delete_env(:gx_portfolio_intelligence, :test_evidence_result)
      Application.delete_env(:gx_portfolio_intelligence, :test_adhoc_missing_ticker)
    end)

    :ok
  end

  test "synthetic 500-member fan-out is complete, ranked and idempotent" do
    {_snapshot, batch} = insert_universe_and_batch(500)

    assert {:ok, first} = Research.ensure_items(batch)
    assert {:ok, second} = Research.ensure_items(batch)
    assert length(first) == 500
    assert length(second) == 500
    assert Repo.aggregate(ResearchItem, :count) == 500
    assert Enum.map(first, & &1.liquidity_rank) == Enum.to_list(1..500)

    jobs =
      for _ <- 1..500 do
        {:ok, job} = RagBatchWorker.new(%{"batch_id" => batch.id}) |> Oban.insert()
        job
      end

    assert length(Enum.uniq_by(jobs, & &1.id)) == 1
    assert Enum.count(jobs, & &1.conflict?) == 499
  end

  test "one RAG state machine claims at most 25 digest documents per turn" do
    Application.put_env(
      :gx_portfolio_intelligence,
      :rag_client,
      CapturingRAGClient
    )

    {_snapshot, batch} = insert_universe_and_batch(30, target_count: 30)
    {:ok, _items} = Research.ensure_items(batch)
    mark_research_complete(batch.id)

    Repo.update_all(
      from(i in ResearchItem, where: i.research_batch_id == ^batch.id),
      set: [digest: %{}]
    )

    assert {:snooze, 1} =
             RagBatchWorker.perform(%Oban.Job{args: %{"batch_id" => batch.id}})

    assert_receive {:rag_batch, 30}
    assert_receive {:rag_documents, documents}
    assert length(documents) == 25
    assert Enum.all?(documents, &(&1["research_mode"] == "eod"))
    assert Enum.all?(documents, &(&1["data_provenance"] == "eod_cutoff"))

    assert Repo.aggregate(from(i in ResearchItem, where: i.rag_status == "submitted"), :count) ==
             25
  end

  test "a crash before RAG submit releases queued rows for idempotent retry" do
    {_snapshot, batch} = insert_universe_and_batch(2)
    {:ok, items} = Research.ensure_items(batch)
    mark_research_complete(batch.id)

    assert {:ok, claimed} = Research.claim_rag_items(batch.id, 25)
    assert length(claimed) == 2
    assert Enum.all?(claimed, &(&1.rag_status == "queued"))

    # A complete remote snapshot with no corresponding documents proves the
    # worker died before its POST became durable. Fresh leases aren't stolen;
    # this simulates the bounded lease expiring after the crash.
    Repo.update_all(
      from(i in ResearchItem, where: i.research_batch_id == ^batch.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -121, :second)]
    )

    assert {:ok, _} = Research.sync_rag_statuses(batch.id, [])
    assert Repo.aggregate(from(i in ResearchItem, where: i.rag_status == "failed"), :count) == 2

    assert {:ok, retried} = Research.claim_rag_items(batch.id, 25)
    assert Enum.map(retried, & &1.id) |> Enum.sort() == Enum.map(items, & &1.id) |> Enum.sort()

    assert {:ok, _} =
             Research.mark_rag_submitted(retried, Map.new(retried, &{&1.ticker, "created"}))

    pending = Enum.map(retried, &%{"ticker" => &1.ticker, "status" => "pending"})
    assert {:ok, _} = Research.sync_rag_statuses(batch.id, pending)
    assert Research.item_counts(batch.id).ready == 0

    ready = Enum.map(retried, &%{"ticker" => &1.ticker, "status" => "ready"})
    assert {:ok, _} = Research.sync_rag_statuses(batch.id, ready)
    assert Research.item_counts(batch.id).ready == 2
  end

  test "an expired submitted RAG lease omitted by the remote snapshot is retryable" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)
    mark_research_complete(batch.id)

    assert {:ok, [claimed]} = Research.claim_rag_items(batch.id, 25)
    assert {:ok, _} = Research.mark_rag_submitted([claimed], %{item.ticker => "created"})

    Repo.update_all(from(i in ResearchItem, where: i.id == ^item.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -121, :second)]
    )

    assert {:ok, _} = Research.sync_rag_statuses(batch.id, [])
    assert Repo.get!(ResearchItem, item.id).rag_status == "failed"
    assert {:ok, [retried]} = Research.claim_rag_items(batch.id, 25)
    assert retried.id == item.id
  end

  test "an expired indexing document omitted by the remote snapshot is retryable" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)

    Repo.update_all(from(i in ResearchItem, where: i.id == ^item.id),
      set: [
        status: "complete",
        rag_status: "indexing",
        updated_at: DateTime.add(DateTime.utc_now(), -121, :second)
      ]
    )

    assert {:ok, _} = Research.sync_rag_statuses(batch.id, [])
    assert Repo.get!(ResearchItem, item.id).rag_status == "failed"
  end

  test "a stale RAG upsert can never become ready through the existing remote document" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)
    mark_research_complete(batch.id)

    assert {:ok, [claimed]} = Research.claim_rag_items(batch.id, 25)
    assert {:ok, _} = Research.mark_rag_submitted([claimed], %{item.ticker => "stale"})

    stale = Repo.get!(ResearchItem, item.id)
    assert stale.rag_status == "stale"
    assert stale.last_error == "rag_stale_source"

    assert {:ok, _} =
             Research.sync_rag_statuses(batch.id, [
               %{"ticker" => item.ticker, "status" => "ready"}
             ])

    still_stale = Repo.get!(ResearchItem, item.id)
    assert still_stale.rag_status == "stale"
    assert is_nil(still_stale.rag_ready_at)
    assert Research.item_counts(batch.id).ready == 0
    assert Research.retryable_items(batch.id) == []
    assert {:ok, 0} = Orchestrator.retry(batch)

    refute Repo.exists?(
             from j in Oban.Job,
               where: j.worker == "GxPortfolioIntelligence.Workers.RagBatchWorker"
           )
  end

  test "RAG polling preserves the first ready timestamp" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)
    first_ready = ~U[2026-08-22 00:59:00Z]

    Repo.update_all(from(i in ResearchItem, where: i.id == ^item.id),
      set: [status: "complete", rag_status: "ready", rag_ready_at: first_ready]
    )

    assert {:ok, _} =
             Research.sync_rag_statuses(batch.id, [
               %{"ticker" => item.ticker, "status" => "ready"}
             ])

    assert DateTime.compare(Repo.get!(ResearchItem, item.id).rag_ready_at, first_ready) == :eq
  end

  test "RAG polling records the remote ready timestamp for SLA audit" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)
    remote_ready = ~U[2026-08-22 00:59:00Z]

    Repo.update_all(from(i in ResearchItem, where: i.id == ^item.id),
      set: [status: "complete", llm_status: "complete", rag_status: "submitted"]
    )

    assert {:ok, _} =
             Research.sync_rag_statuses(batch.id, [
               %{
                 "ticker" => item.ticker,
                 "status" => "ready",
                 "updated_at" => DateTime.to_iso8601(remote_ready)
               }
             ])

    persisted = Repo.get!(ResearchItem, item.id)
    assert persisted.rag_status == "ready"
    assert DateTime.compare(persisted.rag_ready_at, remote_ready) == :eq
  end

  test "manual and recovery orchestration create one final pipeline and recreate discarded work" do
    {_snapshot, batch} = insert_universe_and_batch(1)

    assert {:ok, 5} = Orchestrator.ensure_final_pipeline(batch)
    assert {:ok, 5} = Orchestrator.ensure_final_pipeline(batch)

    jobs = Repo.all(Oban.Job)
    evidence_jobs = Enum.filter(jobs, &String.ends_with?(&1.worker, ".EvidenceWorker"))
    fanout_jobs = Enum.filter(jobs, &String.ends_with?(&1.worker, ".FanoutWorker"))
    assert length(evidence_jobs) == 4
    assert length(fanout_jobs) == 1

    [discarded] = fanout_jobs
    Repo.update_all(from(j in Oban.Job, where: j.id == ^discarded.id), set: [state: "discarded"])

    assert {:ok, 5} = Orchestrator.ensure_final_pipeline(batch)

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == ^discarded.worker),
             :count
           ) == 2
  end

  test "a missing scheduled batch is automatically reconstructed idempotently" do
    date = ~D[2026-08-20]

    assert {:ok, first} = Orchestrator.recover_missing_batch(date)
    assert first.analysis_date == date
    assert first.status == "scheduled"

    assert {:ok, second} = Orchestrator.recover_missing_batch(date)
    assert second.job_id == first.job_id

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "GxPortfolioIntelligence.Workers.UniverseWorker"
      )

    assert length(jobs) == 1
    assert hd(jobs).args["analysis_date"] == Date.to_iso8601(date)
    assert hd(jobs).args["slot"] == "15:15"
    assert hd(jobs).args["frozen"] == true
  end

  test "recovery does not enqueue terminal evidence or repeat fan-out after items exist" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [_item]} = Research.ensure_items(batch)

    Enum.each(
      [{"15:20", "social"}, {"15:20", "media"}, {"15:30", "macro"}, {"15:30", "media"}],
      fn {slot, lane} ->
        {:ok, run} =
          Research.create_evidence_run(%{
            analysis_date: batch.analysis_date,
            slot: slot,
            lane: lane,
            target_count: 1
          })

        assert {:ok, _} =
                 Research.complete_evidence(run, %{
                   "status" => "complete",
                   "target_count" => 1,
                   "processed_count" => 1,
                   "succeeded_count" => 1,
                   "failed_count" => 0,
                   "watermark" => %{}
                 })
      end
    )

    assert {:ok, 0} = Orchestrator.ensure_final_pipeline(batch)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "collector contract rejects a false complete result before opening the barrier" do
    original_runner = Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)
    original_port = Application.get_env(:gx_portfolio_intelligence, :port_runner)
    root = Path.join(System.tmp_dir!(), "gx-pi-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      EvidenceContractRunner
    )

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(original_port, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :trading_agents_runner, original_runner)
      Application.put_env(:gx_portfolio_intelligence, :port_runner, original_port)
      File.rm_rf!(root)
    end)

    {snapshot, _batch} = insert_universe_and_batch(1)

    fingerprint =
      ["X001"]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    base = %{
      "schema_version" => 1,
      "analysis_date" => "2026-08-21",
      "lane" => "social",
      "slot" => "15:20",
      "cutoff" => "2026-08-21T15:20:00+07:00",
      "status" => "complete",
      "target_count" => 1,
      "processed_count" => 0,
      "succeeded_count" => 0,
      "failed_count" => 0,
      "watermark" => %{
        "cutoff" => "2026-08-21T15:20:00+07:00",
        "tickers_fingerprint" => fingerprint
      }
    }

    Application.put_env(:gx_portfolio_intelligence, :test_evidence_result, base)

    job = %Oban.Job{
      args: %{"snapshot_id" => snapshot.id, "lane" => "social", "slot" => "15:20"},
      attempt: 1,
      max_attempts: 8
    }

    assert {:error, :evidence_identity_mismatch} = EvidenceWorker.perform(job)
    refute Research.final_evidence_ready?(snapshot.analysis_date)

    Application.put_env(
      :gx_portfolio_intelligence,
      :test_evidence_result,
      %{base | "processed_count" => 1, "succeeded_count" => 1}
    )

    assert :ok = EvidenceWorker.perform(job)
  end

  test "partial evidence remains retryable and the final-evidence barrier is explicit" do
    {_snapshot, _batch} = insert_universe_and_batch(1)

    required = [{"15:20", "social"}, {"15:20", "media"}, {"15:30", "macro"}, {"15:30", "media"}]

    runs =
      Enum.map(required, fn {slot, lane} ->
        {:ok, run} =
          Research.create_evidence_run(%{
            analysis_date: ~D[2026-08-21],
            slot: slot,
            lane: lane,
            target_count: 1
          })

        run
      end)

    refute Research.final_evidence_ready?(~D[2026-08-21])

    [partial | rest] = runs

    assert {:ok, degraded} =
             Research.complete_evidence(partial, %{
               "status" => "partial",
               "target_count" => 1,
               "processed_count" => 1,
               "succeeded_count" => 1,
               "failed_count" => 0,
               "watermark" => %{
                 "cutoff" => "2026-08-21T15:20:00+07:00",
                 "tickers_fingerprint" => "abc"
               }
             })

    assert degraded.status == "degraded"
    assert degraded.watermark["tickers_fingerprint"] == "abc"
    assert {:ok, retrying} = Research.schedule_evidence_retry(degraded)
    assert retrying.status == "pending"

    Enum.each([retrying | rest], fn run ->
      assert {:ok, terminal} =
               Research.complete_evidence(run, %{
                 "status" => "complete",
                 "target_count" => 1,
                 "processed_count" => 1,
                 "succeeded_count" => 1,
                 "failed_count" => 0,
                 "watermark" => %{}
               })

      assert terminal.status == "complete"
    end)

    assert Research.final_evidence_ready?(~D[2026-08-21])
  end

  test "a frozen universe below 500 is persisted as degraded and emits one alert" do
    original_runner =
      Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)

    original_port = Application.get_env(:gx_portfolio_intelligence, :port_runner)
    root = Path.join(System.tmp_dir!(), "gx-pi-degraded-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      DegradedUniverseRunner
    )

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(original_port, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(
        :gx_portfolio_intelligence,
        :trading_agents_runner,
        original_runner
      )

      Application.put_env(:gx_portfolio_intelligence, :port_runner, original_port)
      File.rm_rf!(root)
    end)

    assert :ok =
             UniverseWorker.perform(%Oban.Job{
               args: %{
                 "analysis_date" => "2026-08-21",
                 "slot" => "15:15",
                 "limit" => 500,
                 "frozen" => true
               }
             })

    batch = Research.latest_batch()
    assert batch.status == "degraded"
    assert batch.universe_snapshot_id

    alert = Repo.get_by!(AlertEvent, event_type: "batch_blocked")
    assert alert.payload["reason"] == "universe_below_target"
  end

  test "a five-ticker manual rollout creates a completable five-item batch" do
    original_runner = Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)
    original_port = Application.get_env(:gx_portfolio_intelligence, :port_runner)
    root = Path.join(System.tmp_dir!(), "gx-pi-rollout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      RolloutUniverseRunner
    )

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(original_port, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :trading_agents_runner, original_runner)
      Application.put_env(:gx_portfolio_intelligence, :port_runner, original_port)
      File.rm_rf!(root)
    end)

    assert :ok =
             UniverseWorker.perform(%Oban.Job{
               args: %{
                 "analysis_date" => "2026-08-21",
                 "slot" => "15:15",
                 "limit" => 5,
                 "frozen" => true
               }
             })

    assert_receive {:rollout_universe_called, _opts}

    batch = Research.latest_batch()
    assert batch.target_count == 5
    assert batch.sla_ready_count == 5
    assert batch.status == "collecting"
    assert {:ok, items} = Research.ensure_items(batch)
    assert length(items) == 5

    assert :ok =
             UniverseWorker.perform(%Oban.Job{
               args: %{
                 "analysis_date" => "2026-08-21",
                 "slot" => "15:15",
                 "limit" => 5,
                 "frozen" => true
               }
             })

    refute_receive {:rollout_universe_called, _opts}
  end

  test "degraded universe sends its actual count to RAG and remains degraded" do
    Application.put_env(
      :gx_portfolio_intelligence,
      :rag_client,
      CapturingRAGClient
    )

    {_snapshot, batch} = insert_universe_and_batch(3, target_count: 500, status: "degraded")
    {:ok, items} = Research.ensure_items(batch)
    mark_research_complete(batch.id, rag_status: "ready")

    Application.put_env(
      :gx_portfolio_intelligence,
      :test_rag_items,
      Enum.map(items, &%{"ticker" => &1.ticker, "status" => "ready"})
    )

    assert :ok = RagBatchWorker.perform(%Oban.Job{args: %{"batch_id" => batch.id}})
    assert_receive {:rag_batch, 3}
    assert_receive {:rag_sealed, batch_id}
    assert batch_id == batch.id
    assert Repo.get!(ResearchBatch, batch.id).status == "degraded"
  end

  test "SLA is met at 490 and missed at 489" do
    {_snapshot, met_batch} = insert_universe_and_batch(500)
    {:ok, _} = Research.ensure_items(met_batch)
    mark_research_complete(met_batch.id, ready_count: 490)

    assert :ok =
             SlaWorker.perform(%Oban.Job{
               args: %{"batch_id" => met_batch.id, "phase" => "final_sla"}
             })

    assert Repo.get!(ResearchBatch, met_batch.id).sla_status == "met"
    assert Repo.aggregate(AlertEvent, :count) == 0

    # Reuse the isolated batch to prove the exact lower boundary.
    Repo.update_all(
      from(i in ResearchItem,
        where: i.research_batch_id == ^met_batch.id and i.liquidity_rank == 490
      ),
      set: [rag_status: "submitted", rag_ready_at: nil]
    )

    met_batch
    |> ResearchBatch.changeset(%{sla_status: "pending"})
    |> Repo.update!()

    assert :ok =
             SlaWorker.perform(%Oban.Job{
               args: %{"batch_id" => met_batch.id, "phase" => "final_sla"}
             })

    missed = Repo.get!(ResearchBatch, met_batch.id)
    assert missed.rag_ready_count == 489
    assert missed.sla_status == "missed"

    assert Repo.get_by!(AlertEvent, event_type: "batch_sla_missed").payload["rag_ready_count"] ==
             489
  end

  test "a delayed SLA job excludes documents first ready after 08:00" do
    {_snapshot, batch} = insert_universe_and_batch(500)
    {:ok, _} = Research.ensure_items(batch)
    mark_research_complete(batch.id, ready_count: 489)

    Repo.update_all(
      from(i in ResearchItem,
        where: i.research_batch_id == ^batch.id and i.liquidity_rank == 490
      ),
      set: [rag_status: "ready", rag_ready_at: ~U[2026-08-22 01:01:00Z]]
    )

    assert :ok =
             SlaWorker.perform(%Oban.Job{
               args: %{"batch_id" => batch.id, "phase" => "final_sla"}
             })

    missed = Repo.get!(ResearchBatch, batch.id)
    assert missed.rag_ready_count == 490
    assert missed.sla_status == "missed"

    alert = Repo.get_by!(AlertEvent, event_type: "batch_sla_missed")
    assert alert.payload["rag_ready_count"] == 489
  end

  test "a missed batch emits recovery as soon as it later reaches 490" do
    {_snapshot, batch} = insert_universe_and_batch(500)
    {:ok, _} = Research.ensure_items(batch)
    mark_research_complete(batch.id, ready_count: 490)

    batch |> ResearchBatch.changeset(%{sla_status: "missed"}) |> Repo.update!()
    {:ok, _} = Research.refresh_batch_counts(batch.id)

    assert :ok =
             SlaWorker.perform(%Oban.Job{
               args: %{"batch_id" => batch.id, "phase" => "recovery"}
             })

    recovered = Repo.get!(ResearchBatch, batch.id)
    assert recovered.sla_status == "missed"
    assert recovered.sla_recovered_at
    assert Repo.get_by!(AlertEvent, event_type: "batch_recovered")
  end

  test "webhook events and Oban research delivery are deduplicated" do
    {_snapshot, batch} = insert_universe_and_batch(1)

    assert {:ok, first_alert} =
             Alerts.emit(:batch_blocked, batch, %{phase: "same", reason: "dependency"})

    assert {:ok, second_alert} =
             Alerts.emit(:batch_blocked, batch, %{phase: "same", reason: "dependency"})

    assert first_alert.id == second_alert.id
    assert Repo.aggregate(AlertEvent, :count) == 1

    alert_jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "GxPortfolioIntelligence.Workers.AlertWorker"
      )

    assert length(alert_jobs) == 1
    [discarded] = alert_jobs
    Repo.update_all(from(j in Oban.Job, where: j.id == ^discarded.id), set: [state: "discarded"])

    assert {:ok, third_alert} =
             Alerts.emit(:batch_blocked, batch, %{phase: "same", reason: "dependency"})

    assert third_alert.id == first_alert.id

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "GxPortfolioIntelligence.Workers.AlertWorker"
             ),
             :count
           ) == 2

    {:ok, [item]} = Research.ensure_items(batch)
    assert {:ok, first_job} = ResearchWorker.new(%{"item_id" => item.id}) |> Oban.insert()
    assert {:ok, duplicate_job} = ResearchWorker.new(%{"item_id" => item.id}) |> Oban.insert()
    assert duplicate_job.conflict?
    assert duplicate_job.id == first_job.id
  end

  test "different blocker reasons create distinct deduplicated alerts" do
    {_snapshot, batch} = insert_universe_and_batch(1)

    assert {:ok, first} =
             Alerts.emit(:batch_blocked, batch, %{phase: "same", reason: "gx_unavailable"})

    assert {:ok, second} =
             Alerts.emit(:batch_blocked, batch, %{phase: "same", reason: "rag_unavailable"})

    refute first.id == second.id
    assert Repo.aggregate(AlertEvent, :count) == 2
  end

  test "universe validation rejects unsafe symbols, exchanges and oversized aliases" do
    base = %{
      "schema_version" => 1,
      "status" => "complete",
      "analysis_date" => "2026-08-21",
      "cutoff" => "2026-08-21T15:15:00+07:00",
      "slot" => "15:15",
      "target_count" => 1,
      "fingerprint" => String.duplicate("c", 64),
      "artifact_path" => "/managed/universe.json"
    }

    member = %{
      "ticker" => "HPG",
      "exchange" => "HOSE",
      "rank" => 1,
      "adtv20" => "1000",
      "adv20" => "100",
      "aliases" => ["Hoa Phat"]
    }

    for unsafe <- [
          %{member | "ticker" => "../HPG"},
          %{member | "exchange" => "OTC"},
          %{member | "aliases" => [String.duplicate("á", 201)]}
        ] do
      assert {:error, :invalid_universe_contract} =
               Research.persist_universe(Map.put(base, "members", [unsafe]), true)
    end
  end

  test "webhook delivery carries a stable receiver idempotency key" do
    original_dispatcher = Application.get_env(:gx_portfolio_intelligence, :alert_dispatcher)

    Application.put_env(
      :gx_portfolio_intelligence,
      :alert_dispatcher,
      CapturingAlertDispatcher
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :alert_dispatcher, original_dispatcher)
    end)

    {_snapshot, batch} = insert_universe_and_batch(1)
    assert {:ok, alert} = Alerts.emit(:batch_blocked, batch, %{reason: "dependency"})

    assert :ok = AlertWorker.perform(%Oban.Job{args: %{"alert_id" => alert.id}})
    assert_receive {:alert_payload, payload}
    assert payload["idempotency_key"] == alert.dedup_key
    assert payload["event"] == "batch_blocked"
  end

  test "manual API accepts rollout limits and the batch list discovers asynchronous results" do
    create_conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> post("/api/v1/research-batches", %{"analysis_date" => "2026-08-21", "limit" => 5})

    assert %{"data" => %{"analysis_date" => "2026-08-21", "status" => "scheduled"}} =
             json_response(create_conn, 202)

    universe_job =
      Repo.one!(
        from j in Oban.Job,
          where: j.worker == "GxPortfolioIntelligence.Workers.UniverseWorker"
      )

    assert universe_job.args["limit"] == 5

    {_snapshot, batch} = insert_universe_and_batch(1)

    list_conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get("/api/v1/research-batches?analysis_date=2026-08-21")

    assert %{"data" => [%{"id" => id}]} = json_response(list_conn, 200)
    assert id == batch.id
  end

  test "ad-hoc API freezes request cutoff and immediately fans out only requested tickers" do
    original_runner = Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)
    original_port = Application.get_env(:gx_portfolio_intelligence, :port_runner)

    original_trend_enabled =
      Application.get_env(:gx_portfolio_intelligence, :trend_enabled, false)

    root = Path.join(System.tmp_dir!(), "gx-pi-adhoc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # Even with trend enabled globally, ad-hoc selections bypass the official
    # EOD hot-ranking flow and retain their request-time cutoff.
    Application.put_env(:gx_portfolio_intelligence, :trend_enabled, true)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      GxPortfolioIntelligence.AdhocCapturingRunner
    )

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(original_port, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :trading_agents_runner, original_runner)
      Application.put_env(:gx_portfolio_intelligence, :port_runner, original_port)

      Application.put_env(
        :gx_portfolio_intelligence,
        :trend_enabled,
        original_trend_enabled
      )

      File.rm_rf!(root)
    end)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "manual-adhoc-001")
      |> post("/api/v1/ad-hoc-research-batches", %{"tickers" => ["hpg", "FPT"]})

    assert %{
             "data" => %{
               "batch_id" => batch_id,
               "batch_type" => "adhoc",
               "evidence_policy" => "archive_as_of_request_cutoff",
               "replayed" => false,
               "tickers" => ["FPT", "HPG"]
             }
           } = json_response(conn, 202)

    assert Plug.Conn.get_resp_header(conn, "location") == [
             "/api/v1/research-batches/#{batch_id}"
           ]

    batch = Repo.get!(ResearchBatch, batch_id)
    assert batch.source == "tradingagents_adhoc_research"
    assert batch.sla_status == "not_applicable"
    assert batch.target_count == 2
    assert is_binary(batch.idempotency_key_hash)
    assert byte_size(batch.idempotency_key_hash) == 64

    universe_job =
      Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == "GxPortfolioIntelligence.Workers.UniverseWorker" and
              j.args["batch_id"] == ^batch.id
      )

    assert universe_job.state == "available"
    assert universe_job.args["tickers"] == ["FPT", "HPG"]
    assert universe_job.args["slot"] == "adhoc-#{batch.id}"
    assert universe_job.args["cutoff"] == DateTime.to_iso8601(batch.cutoff_at)

    assert :ok = UniverseWorker.perform(%Oban.Job{args: universe_job.args})
    assert_receive {:adhoc_universe, opts}
    assert opts[:tickers] == ["FPT", "HPG"]
    assert DateTime.compare(opts[:cutoff], batch.cutoff_at) == :eq

    batch = Repo.get!(ResearchBatch, batch.id)
    assert batch.status == "collecting"
    assert batch.universe_snapshot_id
    assert Research.latest_batch() == nil

    snapshot = Research.snapshot_for(batch.analysis_date, "adhoc-#{batch.id}")
    assert snapshot.metadata["selection"] == "requested_tickers"
    assert snapshot.metadata["requested_tickers"] == ["FPT", "HPG"]

    refute Repo.exists?(
             from j in Oban.Job,
               where: j.worker == "GxPortfolioIntelligence.Workers.EvidenceWorker"
           )

    refute Repo.exists?(
             from j in Oban.Job,
               where: j.worker == "GxPortfolioIntelligence.Workers.TrendWorker"
           )

    fanout_job =
      Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == "GxPortfolioIntelligence.Workers.FanoutWorker" and
              j.args["batch_id"] == ^batch.id
      )

    assert :ok = FanoutWorker.perform(%Oban.Job{args: fanout_job.args})
    items = Research.list_items(batch.id)
    assert Enum.map(items, & &1.ticker) == ["FPT", "HPG"]

    item_ids = MapSet.new(items, & &1.id)

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "GxPortfolioIntelligence.Workers.ResearchWorker"
      )

    assert Enum.count(jobs, &MapSet.member?(item_ids, &1.args["item_id"])) == 2
  end

  test "ad-hoc API is idempotent and rejects key reuse with another ticker set" do
    request = fn tickers ->
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "manual-adhoc-replay")
      |> post("/api/v1/ad-hoc-research-batches", %{"tickers" => tickers})
    end

    first = json_response(request.(["HPG", "FPT"]), 202)
    second = json_response(request.(["FPT", "hpg"]), 202)

    assert first["data"]["batch_id"] == second["data"]["batch_id"]
    assert first["data"]["replayed"] == false
    assert second["data"]["replayed"] == true
    assert Repo.aggregate(ResearchBatch, :count) == 1

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "GxPortfolioIntelligence.Workers.UniverseWorker"
             ),
             :count
           ) == 1

    conflict = request.(["VCB"])

    assert %{"error" => %{"code" => "idempotency_conflict"}} =
             json_response(conflict, 409)
  end

  test "ad-hoc analysis_depth is part of idempotency while omitted digest remains compatible" do
    now = ~U[2026-08-25 02:00:00Z]

    api_conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "analysis-depth-api-001")
      |> post("/api/v1/ad-hoc-research-batches", %{
        "tickers" => ["VCB"],
        "analysis_depth" => "full"
      })

    assert %{"data" => %{"analysis_depth" => "full"}} = json_response(api_conn, 202)

    assert {:ok, full} =
             Orchestrator.create_adhoc_batch(
               ["SSI", "ACB"],
               "analysis-depth-full-001",
               :omitted,
               "full",
               now
             )

    assert full.analysis_depth == "full"
    assert Research.get_batch!(full.batch_id).analysis_depth == "full"

    assert {:ok, replay} =
             Orchestrator.create_adhoc_batch(
               ["ACB", "SSI"],
               "analysis-depth-full-001",
               :omitted,
               "full",
               now
             )

    assert replay.batch_id == full.batch_id
    assert replay.replayed

    assert {:error, :idempotency_conflict} =
             Orchestrator.create_adhoc_batch(
               ["SSI", "ACB"],
               "analysis-depth-full-001",
               :omitted,
               "digest",
               now
             )

    assert {:ok, legacy_digest} =
             Orchestrator.create_adhoc_batch(
               ["HPG"],
               "analysis-depth-digest-001",
               :omitted,
               now
             )

    assert legacy_digest.analysis_depth == "digest"
  end

  test "historical canonical batch upgrades digest to full monotonically across new keys" do
    now = ~U[2026-08-25 02:00:00Z]

    assert {:ok, digest} =
             Orchestrator.create_adhoc_batch(
               ["SSI", "ACB"],
               "historical-depth-digest-001",
               "2026-08-24",
               :omitted,
               now
             )

    assert digest.analysis_depth == "digest"

    assert {:ok, full} =
             Orchestrator.create_adhoc_batch(
               ["ACB", "SSI"],
               "historical-depth-full-001",
               "2026-08-24",
               "full",
               now
             )

    assert full.batch_id == digest.batch_id
    assert full.analysis_depth == "full"
    assert full.replayed

    assert {:ok, no_downgrade} =
             Orchestrator.create_adhoc_batch(
               ["SSI", "ACB"],
               "historical-depth-digest-002",
               "2026-08-24",
               "digest",
               now
             )

    assert no_downgrade.batch_id == digest.batch_id
    assert no_downgrade.analysis_depth == "full"
    assert Research.get_batch!(digest.batch_id).analysis_depth == "full"
  end

  test "historical ad-hoc date freezes 15:00 and canonicalizes new idempotency keys" do
    original_runner = Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)
    original_port = Application.get_env(:gx_portfolio_intelligence, :port_runner)

    root =
      Path.join(System.tmp_dir!(), "gx-pi-historical-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      GxPortfolioIntelligence.AdhocCapturingRunner
    )

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(original_port, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :trading_agents_runner, original_runner)
      Application.put_env(:gx_portfolio_intelligence, :port_runner, original_port)
      File.rm_rf!(root)
    end)

    date = Date.add(GxPortfolioIntelligence.Calendar.today(), -1)
    date_text = Date.to_iso8601(date)

    request = fn key, tickers ->
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> post("/api/v1/ad-hoc-research-batches", %{
        "analysis_date" => date_text,
        "tickers" => tickers
      })
    end

    first = json_response(request.("historical-key-001", ["SSI", "ACB"]), 202)
    second = json_response(request.("historical-key-002", ["acb", "SSI"]), 202)

    assert first["data"]["batch_id"] == second["data"]["batch_id"]
    assert first["data"]["research_mode"] == "historical"
    assert first["data"]["data_provenance"] == "historical_replay"
    assert first["data"]["analysis_date"] == date_text
    assert first["data"]["replayed"] == false
    assert second["data"]["replayed"] == true
    assert second["data"]["job_id"] == first["data"]["job_id"]

    batch = Repo.get!(ResearchBatch, first["data"]["batch_id"])
    assert batch.research_mode == "historical"

    assert DateTime.compare(batch.cutoff_at, DateTime.new!(date, ~T[08:00:00], "Etc/UTC")) ==
             :eq

    assert batch.metadata["cutoff_policy"] == "historical_15_00"
    assert Repo.aggregate(ResearchBatchRequestKey, :count) == 2

    [job] =
      Repo.all(
        from j in Oban.Job,
          where:
            j.worker == "GxPortfolioIntelligence.Workers.UniverseWorker" and
              j.args["batch_id"] == ^batch.id
      )

    assert job.args["price_mode"] == "historical"
    assert :ok = UniverseWorker.perform(%Oban.Job{args: job.args})
    assert_receive {:adhoc_universe, opts}
    assert opts[:price_mode] == "historical"

    bound = Repo.get!(ResearchBatch, batch.id)
    assert bound.universe_snapshot_id
    assert bound.status == "collecting"

    conflict = request.("historical-key-003", ["HPG"])

    assert %{"error" => %{"code" => "historical_batch_conflict"}} =
             json_response(conflict, 409)

    assert Repo.aggregate(ResearchBatch, :count) == 1
    assert Repo.aggregate(ResearchBatchRequestKey, :count) == 2
  end

  test "explicit today remains live while future and malformed dates are rejected" do
    today = GxPortfolioIntelligence.Calendar.today()

    live =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "explicit-today-001")
      |> post("/api/v1/ad-hoc-research-batches", %{
        "analysis_date" => Date.to_iso8601(today),
        "tickers" => ["HPG"]
      })

    assert %{
             "data" => %{
               "research_mode" => "live",
               "data_provenance" => "request_cutoff"
             }
           } = json_response(live, 202)

    invalid_requests = [
      {"future-date-001", Date.to_iso8601(Date.add(today, 1)), "future_analysis_date"},
      {"malformed-date-001", "2026-99-99", "invalid_analysis_date"},
      {"null-date-0001", nil, "invalid_analysis_date"}
    ]

    Enum.each(invalid_requests, fn {key, value, code} ->
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
        |> Plug.Conn.put_req_header("idempotency-key", key)
        |> post("/api/v1/ad-hoc-research-batches", %{
          "analysis_date" => value,
          "tickers" => ["SSI"]
        })

      assert %{"error" => %{"code" => ^code}} = json_response(conn, 422)
    end)

    extra_field =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "extra-field-001")
      |> post("/api/v1/ad-hoc-research-batches", %{
        "analysis_date" => Date.to_iso8601(Date.add(today, -1)),
        "cutoff" => "15:00",
        "tickers" => ["SSI"]
      })

    assert %{"error" => %{"code" => "invalid_adhoc_fields"}} =
             json_response(extra_field, 422)
  end

  test "concurrent historical requests serialize to one canonical batch" do
    date = Date.add(GxPortfolioIntelligence.Calendar.today(), -2) |> Date.to_iso8601()

    tasks =
      for suffix <- ["a", "b"] do
        Task.async(fn ->
          Orchestrator.create_adhoc_batch(
            ["SSI", "ACB"],
            "concurrent-history-#{suffix}",
            date
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.all?(results, &match?({:ok, _}, &1))

    ids = Enum.map(results, fn {:ok, operation} -> operation.batch_id end)
    assert length(Enum.uniq(ids)) == 1
    assert Repo.aggregate(ResearchBatch, :count) == 1
    assert Repo.aggregate(ResearchBatchRequestKey, :count) == 2
  end

  test "concurrent different historical ticker sets produce one winner and one conflict" do
    date = Date.add(GxPortfolioIntelligence.Calendar.today(), -3) |> Date.to_iso8601()

    tasks = [
      Task.async(fn ->
        Orchestrator.create_adhoc_batch(["SSI"], "concurrent-different-a", date)
      end),
      Task.async(fn ->
        Orchestrator.create_adhoc_batch(["ACB"], "concurrent-different-b", date)
      end)
    ]

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :historical_batch_conflict})) == 1
    assert Repo.aggregate(ResearchBatch, :count) == 1
    assert Repo.aggregate(ResearchBatchRequestKey, :count) == 1
  end

  test "database partial index independently rejects a second historical batch for the date" do
    date = Date.add(GxPortfolioIntelligence.Calendar.today(), -4)
    {:ok, cutoff} = GxPortfolioIntelligence.Calendar.at_slot(date, "15:00")

    attrs = fn key ->
      %{
        analysis_date: date,
        cutoff_at: cutoff,
        batch_type: "adhoc",
        research_mode: "historical",
        source: "tradingagents_adhoc_research",
        idempotency_key_hash: String.duplicate(key, 64),
        status: "pending",
        target_count: 1,
        sla_ready_count: 1,
        sla_status: "not_applicable",
        metadata: %{"requested_tickers" => ["HPG"]}
      }
    end

    assert {:ok, _} =
             %ResearchBatch{} |> ResearchBatch.changeset(attrs.("a")) |> Repo.insert()

    assert {:error, changeset} =
             %ResearchBatch{} |> ResearchBatch.changeset(attrs.("b")) |> Repo.insert()

    assert {"has already been taken", _} = changeset.errors[:analysis_date]

    assert {:ok, eod} =
             Research.create_batch(%{
               analysis_date: date,
               cutoff_at: DateTime.add(cutoff, 45, :minute),
               status: "pending",
               target_count: 1,
               sla_ready_count: 1
             })

    assert eod.research_mode == "eod"
  end

  test "an explicit-today idempotency key still replays its live batch on a later day" do
    first_now = ~U[2026-08-25 03:00:00Z]

    assert {:ok, first} =
             Orchestrator.create_adhoc_batch(
               ["HPG"],
               "today-replay-later-001",
               "2026-08-25",
               first_now
             )

    assert first.research_mode == "live"

    assert {:ok, replay} =
             Orchestrator.create_adhoc_batch(
               ["HPG"],
               "today-replay-later-001",
               "2026-08-25",
               ~U[2026-08-26 03:00:00Z]
             )

    assert replay.batch_id == first.batch_id
    assert replay.research_mode == "live"
    assert replay.replayed
    assert Repo.aggregate(ResearchBatch, :count) == 1
  end

  test "ad-hoc batch blocks atomically when a requested ticker is not GX-eligible" do
    original_runner = Application.get_env(:gx_portfolio_intelligence, :trading_agents_runner)
    original_port = Application.get_env(:gx_portfolio_intelligence, :port_runner)

    root =
      Path.join(System.tmp_dir!(), "gx-pi-adhoc-missing-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    Application.put_env(
      :gx_portfolio_intelligence,
      :trading_agents_runner,
      GxPortfolioIntelligence.AdhocCapturingRunner
    )

    Application.put_env(:gx_portfolio_intelligence, :test_adhoc_missing_ticker, true)

    Application.put_env(
      :gx_portfolio_intelligence,
      :port_runner,
      Keyword.put(original_port, :artifact_root, root)
    )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :trading_agents_runner, original_runner)
      Application.put_env(:gx_portfolio_intelligence, :port_runner, original_port)
      File.rm_rf!(root)
    end)

    assert {:ok, operation} =
             Orchestrator.create_adhoc_batch(
               ["HPG", "VCB"],
               "manual-missing-001",
               DateTime.add(DateTime.utc_now(), -1, :second)
             )

    universe_job =
      Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == "GxPortfolioIntelligence.Workers.UniverseWorker" and
              j.args["batch_id"] == ^operation.batch_id
      )

    assert :ok = UniverseWorker.perform(%Oban.Job{args: universe_job.args})

    blocked = Repo.get!(ResearchBatch, operation.batch_id)
    assert blocked.status == "blocked"
    assert blocked.last_error == "requested_tickers_unavailable"
    assert blocked.universe_snapshot_id

    alert = Repo.get_by!(AlertEvent, research_batch_id: blocked.id, event_type: "batch_blocked")
    assert alert.payload["reason"] == "requested_tickers_unavailable"

    refute Repo.exists?(
             from j in Oban.Job,
               where:
                 j.worker == "GxPortfolioIntelligence.Workers.FanoutWorker" and
                   j.args["batch_id"] == ^blocked.id
           )
  end

  test "ad-hoc API validates its idempotency key and ticker set" do
    missing_key =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> post("/api/v1/ad-hoc-research-batches", %{"tickers" => ["HPG"]})

    assert %{"error" => %{"code" => "missing_idempotency_key"}} =
             json_response(missing_key, 422)

    duplicate =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "manual-duplicate-001")
      |> post("/api/v1/ad-hoc-research-batches", %{"tickers" => ["HPG", "hpg"]})

    assert %{"error" => %{"code" => "duplicate_ticker"}} = json_response(duplicate, 422)

    malformed =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "manual-malformed-001")
      |> post("/api/v1/ad-hoc-research-batches", %{"tickers" => [%{"ticker" => "HPG"}]})

    assert %{"error" => %{"code" => "invalid_ticker"}} = json_response(malformed, 422)
    assert Repo.aggregate(ResearchBatch, :count) == 0
  end

  test "EOD and ad-hoc batches can coexist on the same analysis date" do
    now = ~U[2026-08-21 05:00:00Z]

    assert {:ok, adhoc, :created} =
             Research.create_adhoc_batch(%{
               analysis_date: ~D[2026-08-21],
               cutoff_at: now,
               status: "pending",
               target_count: 1,
               sla_ready_count: 1,
               idempotency_key_hash: String.duplicate("1", 64),
               metadata: %{
                 "requested_tickers" => ["HPG"],
                 "request_fingerprint" => String.duplicate("2", 64)
               }
             })

    assert {:ok, eod} =
             Research.create_batch(%{
               analysis_date: ~D[2026-08-21],
               cutoff_at: ~U[2026-08-21 08:45:00Z],
               status: "pending",
               target_count: 1,
               sla_ready_count: 1
             })

    assert adhoc.id != eod.id
    assert Research.batch_for_date(~D[2026-08-21]).id == eod.id
    assert Research.latest_batch().id == eod.id

    assert Enum.map(Research.list_batches(analysis_date: ~D[2026-08-21]), & &1.batch_type) == [
             "eod",
             "adhoc"
           ]
  end

  test "research item API paginates server-side and never exposes artifacts or digest bodies" do
    {_snapshot, batch} = insert_universe_and_batch(3)
    {:ok, _} = Research.ensure_items(batch)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get("/api/v1/research-batches/#{batch.id}/items?limit=2&offset=1")

    assert %{"data" => items, "pagination" => pagination} = json_response(conn, 200)
    assert Enum.map(items, & &1["liquidity_rank"]) == [2, 3]
    assert pagination == %{"limit" => 2, "offset" => 1, "returned" => 2}

    encoded = Jason.encode!(items)
    refute encoded =~ "artifact_path"
    refute encoded =~ "rag_envelope_path"
    refute encoded =~ "sections"
  end

  test "a failed in-flight research claim is resumable" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)

    assert {:ok, running} = Research.claim_item(item.id)
    assert running.status == "running"
    assert {:ok, failed} = Research.fail_item(running, :simulated_python_crash)
    assert failed.status == "failed"
    assert {:ok, resumed} = Research.claim_item(item.id)
    assert resumed.status == "running"
  end

  test "maintenance can recreate work for an item left running after a hard crash" do
    {_snapshot, batch} = insert_universe_and_batch(1)
    {:ok, [item]} = Research.ensure_items(batch)
    assert {:ok, running} = Research.claim_item(item.id)
    assert running.status == "running"

    assert Enum.map(Research.retryable_items(batch.id), & &1.id) == [item.id]
    assert {:ok, 1} = Orchestrator.retry(batch)

    jobs =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "GxPortfolioIntelligence.Workers.ResearchWorker"
      )

    assert Enum.any?(jobs, &(&1.args["item_id"] == item.id))
  end

  test "all historical incomplete batches remain visible to maintenance" do
    for offset <- 0..100 do
      date = Date.add(~D[2025-01-01], offset)

      assert {:ok, _batch} =
               Research.create_batch(%{
                 analysis_date: date,
                 cutoff_at: DateTime.new!(date, ~T[09:45:00], "Etc/UTC"),
                 status: "pending",
                 target_count: 1,
                 sla_ready_count: 1
               })
    end

    batches = Research.list_recoverable_batches()
    assert length(batches) == 101
    assert List.last(batches).analysis_date == ~D[2025-01-01]
  end

  defp insert_universe_and_batch(count, opts \\ []) do
    target_count = Keyword.get(opts, :target_count, 500)

    status =
      Keyword.get(opts, :status, if(count < target_count, do: "degraded", else: "collecting"))

    now = DateTime.utc_now()

    snapshot =
      %UniverseSnapshot{}
      |> UniverseSnapshot.changeset(%{
        analysis_date: ~D[2026-08-21],
        slot: "15:15",
        cutoff_at: ~U[2026-08-21 08:15:00Z],
        member_limit: target_count,
        member_count: count,
        status: if(count < target_count, do: "degraded", else: "complete"),
        frozen: true,
        fingerprint: String.duplicate("a", 64)
      })
      |> Repo.insert!()

    rows =
      for rank <- 1..count do
        %{
          universe_snapshot_id: snapshot.id,
          ticker: "X" <> String.pad_leading(Integer.to_string(rank), 3, "0"),
          exchange: "HOSE",
          rank: rank,
          adtv20: Decimal.new(1_000_000 - rank),
          adv20: Decimal.new(100_000 - rank),
          metadata: %{"aliases" => []},
          inserted_at: now
        }
      end

    {^count, nil} = Repo.insert_all(UniverseMember, rows)

    batch =
      %ResearchBatch{}
      |> ResearchBatch.changeset(%{
        analysis_date: ~D[2026-08-21],
        cutoff_at: ~U[2026-08-21 09:45:00Z],
        status: status,
        target_count: target_count,
        sla_ready_count: min(490, target_count),
        universe_snapshot_id: snapshot.id
      })
      |> Repo.insert!()

    {snapshot, batch}
  end

  defp mark_research_complete(batch_id, opts \\ []) do
    ready_count = Keyword.get(opts, :ready_count, 0)
    all_rag_status = Keyword.get(opts, :rag_status)

    Repo.update_all(
      from(i in ResearchItem, where: i.research_batch_id == ^batch_id),
      set: [status: "complete", llm_status: "complete"]
    )

    cond do
      is_binary(all_rag_status) ->
        Repo.update_all(
          from(i in ResearchItem, where: i.research_batch_id == ^batch_id),
          set: [rag_status: all_rag_status]
        )

      ready_count > 0 ->
        Repo.update_all(
          from(i in ResearchItem,
            where: i.research_batch_id == ^batch_id and i.liquidity_rank <= ^ready_count
          ),
          set: [rag_status: "ready", rag_ready_at: ~U[2026-08-22 00:59:00Z]]
        )

      true ->
        :ok
    end
  end
end
