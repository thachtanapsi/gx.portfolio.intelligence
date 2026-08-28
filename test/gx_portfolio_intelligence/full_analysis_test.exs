defmodule GxPortfolioIntelligence.FullAnalysisTest do
  use GxPortfolioIntelligence.DataCase, async: false

  import Phoenix.ConnTest

  alias GxPortfolioIntelligence.{
    FullAnalysis,
    FullReportEnvelope,
    FullReportResponse,
    Repo,
    Research
  }

  alias GxPortfolioIntelligence.Schemas.{
    AlertEvent,
    FullAnalysisItem,
    ResearchBatch,
    ResearchItem,
    ResearchStageRun,
    TrendMember,
    TrendSnapshot,
    UniverseMember,
    UniverseSnapshot
  }

  @endpoint GxPortfolioIntelligenceWeb.Endpoint

  setup do
    original_limit = Application.get_env(:gx_portfolio_intelligence, :full_analysis_limit)

    original_pinned =
      Application.get_env(:gx_portfolio_intelligence, :full_analysis_pinned_tickers)

    original_enabled =
      Application.get_env(:gx_portfolio_intelligence, :full_analysis_enabled)

    original_full_report_response =
      Application.get_env(:gx_portfolio_intelligence, :test_full_report_response)

    original_backlog_threshold =
      Application.get_env(
        :gx_portfolio_intelligence,
        :full_analysis_backlog_warning_threshold
      )

    on_exit(fn ->
      Application.put_env(:gx_portfolio_intelligence, :full_analysis_limit, original_limit)

      Application.put_env(
        :gx_portfolio_intelligence,
        :full_analysis_pinned_tickers,
        original_pinned
      )

      Application.put_env(:gx_portfolio_intelligence, :full_analysis_enabled, original_enabled)

      if is_nil(original_full_report_response) do
        Application.delete_env(:gx_portfolio_intelligence, :test_full_report_response)
      else
        Application.put_env(
          :gx_portfolio_intelligence,
          :test_full_report_response,
          original_full_report_response
        )
      end

      Application.put_env(
        :gx_portfolio_intelligence,
        :full_analysis_backlog_warning_threshold,
        original_backlog_threshold
      )
    end)

    :ok
  end

  test "frozen trend validates the exact weight contract and pins only official top-500 members" do
    Application.put_env(:gx_portfolio_intelligence, :full_analysis_limit, 2)

    Application.put_env(
      :gx_portfolio_intelligence,
      :full_analysis_pinned_tickers,
      ["bbb", "BBB", " BBB "]
    )

    universe =
      %UniverseSnapshot{}
      |> UniverseSnapshot.changeset(%{
        analysis_date: ~D[2026-08-25],
        slot: "15:15",
        cutoff_at: ~U[2026-08-25 08:15:00Z],
        member_limit: 3,
        member_count: 3,
        status: "complete",
        frozen: true,
        fingerprint: String.duplicate("a", 64)
      })
      |> Repo.insert!()

    [
      {"AAA", 1, "100"},
      {"BBB", 2, "90"},
      {"CCC", 3, "80"}
    ]
    |> Enum.each(fn {ticker, rank, adtv20} ->
      %UniverseMember{}
      |> UniverseMember.changeset(%{
        universe_snapshot_id: universe.id,
        ticker: ticker,
        exchange: "HOSE",
        rank: rank,
        adtv20: adtv20,
        adv20: "10"
      })
      |> Repo.insert!()
    end)

    result =
      %{
        "schema_version" => 1,
        "analysis_date" => "2026-08-25",
        "cutoff" => "2026-08-25T08:00:00Z",
        "previous_cutoff" => "2026-08-25T07:15:00Z",
        "slot" => "15:15",
        "universe_fingerprint" => String.duplicate("a", 64),
        "weights" => %{
          "volume_ratio" => 30,
          "daily_move_abs" => 25,
          "momentum20_abs" => 15,
          "social_attention" => 15,
          "media_event" => 15
        },
        "status" => "degraded",
        "target_count" => 3,
        "scored_count" => 2,
        "fingerprint" => String.duplicate("b", 64),
        "members" => [
          trend_member("AAA", 1, "100", "10"),
          trend_member("BBB", 2, "90", "10"),
          trend_member("CCC", 3, "80", nil, false)
        ],
        "warnings" => ["optional_attention_missing"]
      }
      |> with_trend_fingerprint()

    tampered = put_in(result, ["members", Access.at(0), "trend_score"], "11")

    assert {:error, :invalid_trend_contract} =
             FullAnalysis.persist_trend(tampered, Repo.preload(universe, :members),
               cutoff: ~U[2026-08-25 08:00:00Z],
               previous_cutoff: ~U[2026-08-25 07:15:00Z],
               artifact_path: "/managed/trends/2026-08-25/15:15.json",
               frozen: true
             )

    assert {:ok, trend} =
             FullAnalysis.persist_trend(result, Repo.preload(universe, :members),
               cutoff: ~U[2026-08-25 08:00:00Z],
               previous_cutoff: ~U[2026-08-25 07:15:00Z],
               artifact_path: "/managed/trends/2026-08-25/15:15.json",
               frozen: true
             )

    assert FullAnalysis.pinned_tickers() == ["BBB"]
    assert trend.selected_count == 2

    assert [
             %TrendMember{ticker: "BBB", selection_rank: 1, pinned: true},
             %TrendMember{ticker: "AAA", selection_rank: 2, pinned: false}
           ] =
             Repo.all(
               from m in TrendMember,
                 where: m.trend_snapshot_id == ^trend.id and m.selected == true,
                 order_by: m.selection_rank
             )
  end

  test "trend rejects a payload that omits an official frozen member" do
    suffix = System.unique_integer([:positive])

    universe =
      %UniverseSnapshot{}
      |> UniverseSnapshot.changeset(%{
        analysis_date: ~D[2026-08-25],
        slot: "missing-#{suffix}",
        cutoff_at: ~U[2026-08-25 08:15:00Z],
        member_limit: 2,
        member_count: 2,
        status: "complete",
        frozen: true,
        fingerprint: String.duplicate("9", 64)
      })
      |> Repo.insert!()

    Enum.each([{"AAA", 1}, {"BBB", 2}], fn {ticker, rank} ->
      %UniverseMember{}
      |> UniverseMember.changeset(%{
        universe_snapshot_id: universe.id,
        ticker: ticker,
        exchange: "HOSE",
        rank: rank,
        adtv20: Integer.to_string(100 - rank),
        adv20: "10"
      })
      |> Repo.insert!()
    end)

    result =
      %{
        "schema_version" => 1,
        "analysis_date" => "2026-08-25",
        "cutoff" => "2026-08-25T08:00:00Z",
        "previous_cutoff" => "2026-08-25T07:15:00Z",
        "slot" => "missing-#{suffix}",
        "universe_fingerprint" => String.duplicate("9", 64),
        "weights" => FullAnalysis.trend_weights(),
        "status" => "degraded",
        "target_count" => 2,
        "scored_count" => 1,
        "fingerprint" => String.duplicate("8", 64),
        "members" => [trend_member("AAA", 1, "99", "10")],
        "warnings" => ["market_core_missing"]
      }
      |> with_trend_fingerprint()

    assert {:error, :invalid_trend_members} =
             FullAnalysis.persist_trend(result, Repo.preload(universe, :members),
               cutoff: ~U[2026-08-25 08:00:00Z],
               previous_cutoff: ~U[2026-08-25 07:15:00Z],
               artifact_path: "/managed/trends/missing.json",
               frozen: true
             )
  end

  test "stage claims exclude duplicates, reclaim expired leases and skip terminal stages" do
    {_batch, _research_item, full, item} = full_fixture()
    stage = item.id |> FullAnalysis.list_stages() |> hd()

    assert {:ok, claimed, first_key} = FullAnalysis.claim_stage(stage)
    assert claimed.status == "running"
    assert claimed.attempt_count == 1
    assert {:busy, _} = FullAnalysis.claim_stage(stage)

    Repo.update_all(
      from(s in ResearchStageRun, where: s.id == ^stage.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, reclaimed, second_key} = FullAnalysis.claim_stage(stage)
    assert second_key != first_key
    assert reclaimed.attempt_count == 2

    assert {:error, :stage_claim_lost} =
             FullAnalysis.mark_stage_failed(reclaimed, first_key, :provider_failed)

    assert %ResearchStageRun{status: "running", claim_key: ^second_key} =
             Repo.get!(ResearchStageRun, stage.id)

    assert %FullAnalysisItem{status: "running", last_error: nil} =
             Repo.get!(FullAnalysisItem, item.id)

    assert {:error, :stage_claim_lost} =
             FullAnalysis.release_stage_claim(reclaimed, first_key)

    assert :ok = FullAnalysis.release_stage_claim(reclaimed, second_key)

    assert %ResearchStageRun{status: "pending", claim_key: nil} =
             Repo.get!(ResearchStageRun, stage.id)

    assert {:ok, reclaimed, third_key} =
             ResearchStageRun |> Repo.get!(stage.id) |> FullAnalysis.claim_stage()

    assert reclaimed.attempt_count == 3

    result = %{
      "identity_hash" => item.identity_hash,
      "stage" => "market",
      "status" => "complete",
      "stage_status" => "complete",
      "stage_terminal" => true,
      "stage_fingerprint" => String.duplicate("e", 64),
      "terminal_stages" => ["market"],
      "next_stage" => "sentiment"
    }

    assert {:error, :stage_claim_lost} =
             FullAnalysis.complete_stage(reclaimed, first_key, result)

    assert {:ok, completed} = FullAnalysis.complete_stage(reclaimed, third_key, result)
    assert completed.status == "complete"
    assert completed.claim_key == nil
    assert {:already_complete, _} = FullAnalysis.claim_stage(completed)
    assert FullAnalysis.get_batch_for_research(full.research_batch_id)
  end

  test "status reconciliation advances only stages listed as terminal" do
    {_batch, _research_item, _full, item} = full_fixture()

    nonterminal = %{
      "identity_hash" => item.identity_hash,
      "parent_identity_hash" => item.parent_identity_hash,
      "stage_status" => %{"market" => "partial"},
      "stage_fingerprints" => %{"market" => String.duplicate("a", 64)},
      "terminal_stages" => []
    }

    assert {:ok, reconciled} = FullAnalysis.reconcile_status(item, nonterminal)
    assert FullAnalysis.next_stage(reconciled).stage == "market"

    terminal = Map.put(nonterminal, "terminal_stages", ["market"])
    assert {:ok, reconciled} = FullAnalysis.reconcile_status(item, terminal)
    assert FullAnalysis.next_stage(reconciled).stage == "sentiment"
    assert hd(FullAnalysis.list_stages(item.id)).status == "partial"
  end

  test "explicit restart is idempotent, increments generation once and rejects promoted items" do
    {batch, _research_item, full, item} = full_fixture(item_status: "failed")

    assert {:ok, 1, false} = FullAnalysis.restart(full, "restart-full-001", [item.ticker])
    restarted = Repo.get!(FullAnalysisItem, item.id)
    assert restarted.execution_generation == 2
    assert restarted.status == "pending"
    assert is_nil(restarted.identity_hash)

    assert {:ok, 1, true} = FullAnalysis.restart(full, "restart-full-001", [item.ticker])
    assert Repo.get!(FullAnalysisItem, item.id).execution_generation == 2

    Repo.update_all(
      from(i in FullAnalysisItem, where: i.id == ^item.id),
      set: [
        status: "complete",
        rag_status: "ready",
        full_report_hash: String.duplicate("f", 64),
        promoted_at: DateTime.utc_now()
      ]
    )

    assert {:error, :full_analysis_already_promoted} =
             FullAnalysis.restart(full, "restart-full-002", [item.ticker])

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> Plug.Conn.put_req_header("idempotency-key", "restart-full-api-001")
      |> post("/api/v1/research-batches/#{batch.id}/full-analysis/retry", %{
        "mode" => "restart",
        "tickers" => [item.ticker]
      })

    assert %{"error" => %{"code" => "full_analysis_already_promoted"}} =
             json_response(conn, 409)
  end

  test "restart idempotency key cannot replay against another full batch" do
    {_batch_one, _research_item_one, full_one, item_one} = full_fixture(item_status: "failed")
    {_batch_two, _research_item_two, full_two, item_two} = full_fixture(item_status: "failed")

    key = "restart-cross-batch-001"

    assert {:ok, 1, false} = FullAnalysis.restart(full_one, key, [item_one.ticker])

    assert {:error, :idempotency_conflict} =
             FullAnalysis.restart(full_two, key, [item_two.ticker])

    assert Repo.get!(FullAnalysisItem, item_two.id).execution_generation == 1
  end

  test "restart API rejects non-string ticker values with 422" do
    {batch, _research_item, _full, _item} = full_fixture(item_status: "failed")

    for {suffix, tickers} <- [
          {"object", [%{"ticker" => "SSI"}]},
          {"list", [["SSI"]]},
          {"number", [123]},
          {"boolean", [true]}
        ] do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
        |> Plug.Conn.put_req_header("idempotency-key", "restart-invalid-#{suffix}")
        |> post("/api/v1/research-batches/#{batch.id}/full-analysis/retry", %{
          "mode" => "restart",
          "tickers" => tickers
        })

      assert %{"error" => %{"code" => "invalid_restart_tickers"}} =
               json_response(conn, 422)
    end
  end

  test "existing item API exposes digest and full-analysis compatibility fields" do
    {batch, _research_item, _full, item} = full_fixture()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get("/api/v1/research-batches/#{batch.id}/items?limit=50")

    assert %{
             "data" => [
               %{
                 "analysis_depth" => "full",
                 "full_status" => "running",
                 "full_current_stage" => "market",
                 "full_completed_stages" => 0,
                 "full_report_hash" => nil,
                 "full_rag_status" => "pending",
                 "last_error_code" => nil
               }
             ]
           } = json_response(conn, 200)

    assert item.ticker == "SSI"
  end

  test "ready and stale full items produce a disjoint degraded terminal batch" do
    {batch, _research_item, full, item} = full_fixture()

    item
    |> FullAnalysisItem.changeset(%{
      status: "complete",
      rag_status: "ready",
      full_report_hash: String.duplicate("f", 64),
      promoted_at: DateTime.utc_now()
    })
    |> Repo.update!()

    second_research =
      %ResearchItem{}
      |> ResearchItem.changeset(%{
        research_batch_id: batch.id,
        ticker: "ACB",
        liquidity_rank: 2,
        status: "partial",
        llm_status: "partial",
        rag_status: "ready",
        identity_hash: String.duplicate("1", 64),
        digest_hash: String.duplicate("2", 64)
      })
      |> Repo.insert!()

    %FullAnalysisItem{}
    |> FullAnalysisItem.changeset(%{
      full_analysis_batch_id: full.id,
      research_item_id: second_research.id,
      ticker: "ACB",
      selection_rank: 2,
      liquidity_rank: 2,
      status: "failed",
      rag_status: "stale",
      execution_key: String.duplicate("3", 64),
      execution_generation: 1,
      last_error: "full_report_stale"
    })
    |> Repo.insert!()

    assert {:ok, refreshed} = FullAnalysis.refresh_batch(full.id)
    assert refreshed.status == "degraded"
    assert refreshed.target_count == 2
    assert refreshed.completed_count == 1
    assert refreshed.promoted_count == 1
    assert refreshed.failed_count == 0
    assert refreshed.blocked_count == 1
    assert refreshed.completed_at
  end

  test "recovery binds completed digest identity before enqueueing full analysis" do
    {_batch, research_item, _full, item} = full_fixture(item_status: "pending")

    item
    |> FullAnalysisItem.changeset(%{
      parent_identity_hash: nil,
      expected_digest_hash: nil,
      identity_hash: nil
    })
    |> Repo.update!()

    assert {:ok, 1} = FullAnalysis.recover_incomplete()

    rebound = Repo.get!(FullAnalysisItem, item.id)
    assert rebound.parent_identity_hash == research_item.identity_hash
    assert rebound.expected_digest_hash == research_item.digest_hash

    assert Repo.exists?(
             from j in Oban.Job,
               where:
                 j.worker == "GxPortfolioIntelligence.Workers.FullAnalysisWorker" and
                   fragment("?->>'item_id'", j.args) == ^to_string(item.id)
           )
  end

  test "full report response validates hashes, identity, sizes and target contract" do
    {batch, _research_item, _full, item} = full_fixture()
    response = full_report_response(batch, item)
    expected = full_report_expected(batch, item, response)

    assert {:ok, data} = FullReportResponse.validate(response, expected)
    assert data["decision"]["portfolio"]["price_target"] == 77_000
    assert data["report"]["full_report_hash"] == expected.full_report_hash

    canonical_mismatch =
      put_in(response, ["data", "canonical_report_sha256"], String.duplicate("0", 64))

    assert {:error, :canonical_report_hash_mismatch} =
             FullReportResponse.validate(canonical_mismatch, expected)

    identity_mismatch = put_in(response, ["data", "report", "ticker"], "FPT")

    assert {:error, :full_report_identity_mismatch} =
             FullReportResponse.validate(identity_mismatch, expected)

    bad_target = put_in(response, ["data", "decision", "portfolio", "price_target"], 77_000.5)

    assert {:error, :invalid_price_target_contract} =
             FullReportResponse.validate(bad_target, expected)

    oversized =
      put_in(
        response,
        ["data", "decision", "trading", "reasoning"],
        String.duplicate("x", 65_536)
      )

    assert {:error, :decision_too_large} = FullReportResponse.validate(oversized, expected)

    extra_key = put_in(response, ["data", "unexpected"], true)
    assert {:error, :invalid_response_fields} = FullReportResponse.validate(extra_key, expected)

    unavailable =
      response
      |> put_in(["data", "decision", "portfolio", "price_target_status"], "unavailable")
      |> put_in(["data", "decision", "portfolio", "price_target"], nil)
      |> put_in(["data", "decision", "portfolio", "price_target_currency"], nil)
      |> put_in(["data", "decision", "portfolio", "price_target_rationale"], nil)
      |> put_in(
        ["data", "decision", "portfolio", "price_target_unavailable_reason"],
        "Không có dữ liệu định giá đủ tin cậy."
      )
      |> rehash_decision()

    assert {:ok, unavailable_data} = FullReportResponse.validate(unavailable, expected)
    assert unavailable_data["decision"]["portfolio"]["price_target"] == nil

    partial =
      response
      |> put_in(["data", "decision", "status"], "partial")
      |> put_in(["data", "decision", "warnings"], ["portfolio_rating_missing"])
      |> put_in(["data", "decision", "portfolio", "rating"], nil)
      |> put_in(["data", "decision", "portfolio", "price_target_status"], "unknown")
      |> put_in(["data", "decision", "portfolio", "price_target"], nil)
      |> put_in(["data", "decision", "portfolio", "price_target_currency"], nil)
      |> put_in(["data", "decision", "portfolio", "price_target_rationale"], nil)
      |> put_in(["data", "decision", "portfolio", "price_target_unavailable_reason"], nil)
      |> rehash_decision()

    assert {:ok, partial_data} = FullReportResponse.validate(partial, expected)
    assert partial_data["decision"]["status"] == "partial"
  end

  test "full report API enforces auth and maps local/RAG readiness failures" do
    {batch, _research_item, _full, item} = full_fixture()
    endpoint = "/api/v1/research-batches/#{batch.id}/full-analysis/items/#{item.ticker}/report"

    unauthenticated = build_conn() |> get(endpoint)
    assert json_response(unauthenticated, 401)["error"]["code"] == "unauthorized"

    not_ready =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get(endpoint)

    assert %{"error" => %{"code" => "full_report_not_ready"}} = json_response(not_ready, 409)

    missing =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get("/api/v1/research-batches/#{batch.id}/full-analysis/items/MISSING/report")

    assert %{"error" => %{"code" => "full_analysis_item_not_found"}} =
             json_response(missing, 404)

    response = full_report_response(batch, item)

    ready =
      item
      |> FullAnalysisItem.changeset(%{
        status: "complete",
        rag_status: "ready",
        full_report_hash: response["data"]["report"]["full_report_hash"],
        promoted_at: DateTime.utc_now()
      })
      |> Repo.update!()

    Application.put_env(
      :gx_portfolio_intelligence,
      :test_full_report_response,
      {:ok, response}
    )

    success =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get(endpoint)

    assert %{
             "data" => %{
               "document_id" => "digest_" <> _,
               "decision" => %{
                 "portfolio" => %{"price_target" => 77_000},
                 "trading" => %{"action" => "Buy"}
               }
             }
           } = json_response(success, 200)

    invalid = put_in(response, ["data", "report", "full_report_hash"], String.duplicate("0", 64))

    Application.put_env(
      :gx_portfolio_intelligence,
      :test_full_report_response,
      {:ok, invalid}
    )

    unavailable =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get(endpoint)

    assert %{"error" => %{"code" => "full_report_unavailable"}} =
             json_response(unavailable, 503)

    Application.put_env(
      :gx_portfolio_intelligence,
      :test_full_report_response,
      {:error, :rag_unavailable}
    )

    rag_down =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer test-api-token")
      |> get(endpoint)

    assert %{"error" => %{"code" => "full_report_unavailable"}} =
             json_response(rag_down, 503)

    assert ready.rag_status == "ready"
  end

  test "synthetic EOD 500 full analysis is bounded and leaves digest SLA untouched" do
    Application.put_env(:gx_portfolio_intelligence, :full_analysis_enabled, true)
    Application.put_env(:gx_portfolio_intelligence, :full_analysis_limit, 500)
    Application.put_env(:gx_portfolio_intelligence, :full_analysis_pinned_tickers, [])
    Application.put_env(:gx_portfolio_intelligence, :full_analysis_backlog_warning_threshold, 20)

    now = DateTime.utc_now()

    universe =
      %UniverseSnapshot{}
      |> UniverseSnapshot.changeset(%{
        analysis_date: ~D[2026-08-25],
        slot: "15:15",
        cutoff_at: ~U[2026-08-25 08:15:00Z],
        member_limit: 500,
        member_count: 500,
        status: "complete",
        frozen: true,
        fingerprint: String.duplicate("4", 64)
      })
      |> Repo.insert!()

    universe_rows =
      for rank <- 1..500 do
        %{
          universe_snapshot_id: universe.id,
          ticker: synthetic_ticker(rank),
          exchange: "HOSE",
          rank: rank,
          adtv20: Decimal.new(1_000_000 - rank),
          adv20: Decimal.new(100_000 - rank),
          metadata: %{},
          inserted_at: now
        }
      end

    assert {500, _} = Repo.insert_all(UniverseMember, universe_rows)

    trend =
      %TrendSnapshot{}
      |> TrendSnapshot.changeset(%{
        universe_snapshot_id: universe.id,
        analysis_date: universe.analysis_date,
        cutoff_at: ~U[2026-08-25 08:00:00Z],
        previous_cutoff_at: ~U[2026-08-25 07:15:00Z],
        slot: universe.slot,
        status: "complete",
        target_count: 500,
        scored_count: 500,
        selected_count: 500,
        universe_fingerprint: universe.fingerprint,
        fingerprint: String.duplicate("5", 64),
        weights: FullAnalysis.trend_weights(),
        warnings: [],
        frozen: true
      })
      |> Repo.insert!()

    trend_rows =
      for rank <- 1..500 do
        %{
          trend_snapshot_id: trend.id,
          ticker: synthetic_ticker(rank),
          liquidity_rank: rank,
          adtv20: Decimal.new(1_000_000 - rank),
          adv20: Decimal.new(100_000 - rank),
          market_core_available: true,
          coverage: %{
            "market_core" => true,
            "social_attention" => false,
            "media_event" => false
          },
          trend_score: Decimal.new(501 - rank),
          selected: true,
          selection_rank: rank,
          pinned: false,
          metadata: %{},
          inserted_at: now
        }
      end

    assert {500, _} = Repo.insert_all(TrendMember, trend_rows)

    batch =
      %ResearchBatch{}
      |> ResearchBatch.changeset(%{
        analysis_date: universe.analysis_date,
        cutoff_at: ~U[2026-08-25 08:45:00Z],
        batch_type: "eod",
        research_mode: "eod",
        analysis_depth: "full",
        source: "tradingagents_daily_research",
        status: "completed",
        target_count: 500,
        completed_count: 500,
        rag_ready_count: 500,
        failed_count: 0,
        sla_ready_count: 490,
        sla_status: "met",
        started_at: now,
        completed_at: now,
        universe_snapshot_id: universe.id,
        metadata: %{"data_provenance" => "eod_cutoff"}
      })
      |> Repo.insert!()

    assert {:ok, items} = Research.ensure_items(batch)
    assert length(items) == 500

    Repo.update_all(
      from(i in ResearchItem, where: i.research_batch_id == ^batch.id),
      set: [
        status: "partial",
        llm_status: "partial",
        rag_status: "ready",
        identity_hash: String.duplicate("6", 64),
        digest_hash: String.duplicate("7", 64),
        completed_at: now,
        rag_ready_at: now,
        updated_at: now
      ]
    )

    assert {:ok, full} = FullAnalysis.ensure_for_research_batch(batch, trend)
    assert full.target_count == 500

    completed_items =
      Repo.all(
        from i in ResearchItem,
          where: i.research_batch_id == ^batch.id,
          order_by: i.liquidity_rank
      )

    Enum.each(completed_items, fn item ->
      assert {:ok, %FullAnalysisItem{}} = FullAnalysis.maybe_schedule_item(item)
    end)

    assert Repo.aggregate(
             from(i in FullAnalysisItem, where: i.full_analysis_batch_id == ^full.id),
             :count
           ) == 500

    assert Repo.aggregate(
             from(s in ResearchStageRun,
               join: i in FullAnalysisItem,
               on: i.id == s.full_analysis_item_id,
               where: i.full_analysis_batch_id == ^full.id
             ),
             :count
           ) == 3_500

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "GxPortfolioIntelligence.Workers.FullAnalysisWorker"
             ),
             :count
           ) == 500

    assert Repo.aggregate(
             from(a in AlertEvent,
               where:
                 a.research_batch_id == ^batch.id and
                   a.event_type == "dependency_unhealthy"
             ),
             :count
           ) == 1

    unchanged = Repo.get!(ResearchBatch, batch.id)
    assert unchanged.status == "completed"
    assert unchanged.target_count == 500
    assert unchanged.completed_count == 500
    assert unchanged.rag_ready_count == 500
    assert unchanged.failed_count == 0
    assert unchanged.sla_ready_count == 490
    assert unchanged.sla_status == "met"
  end

  defp trend_member(ticker, rank, adtv20, score, core \\ true) do
    %{
      "ticker" => ticker,
      "liquidity_rank" => rank,
      "adtv20" => adtv20,
      "adv20" => "10",
      "market_core_available" => core,
      "volume_ratio" => if(core, do: "1.2", else: nil),
      "daily_move_abs_pct" => if(core, do: "2.5", else: nil),
      "momentum20_abs_pct" => if(core, do: "4.0", else: nil),
      "social_attention_velocity" => nil,
      "media_event_velocity" => nil,
      "coverage" => %{
        "market_core" => core,
        "social_attention" => false,
        "media_event" => false
      },
      "trend_score" => score
    }
  end

  defp with_trend_fingerprint(result),
    do: Map.put(result, "fingerprint", FullAnalysis.trend_fingerprint(result))

  defp synthetic_ticker(rank),
    do: "S" <> String.pad_leading(Integer.to_string(rank), 3, "0")

  defp full_report_response(batch, item) do
    stages = ~w(market sentiment news fundamentals research trader risk)
    stage_status = Map.new(stages, &{&1, "complete"})
    stage_fingerprints = Map.new(stages, &{&1, FullReportEnvelope.canonical_sha256(&1)})

    sections =
      Map.new(FullReportEnvelope.sections(), fn section ->
        text =
          case section do
            "portfolio.decision" ->
              "**Rating**: Overweight\n\n**Executive Summary**: Tích lũy dần.\n\n" <>
                "**Investment Thesis**: Tăng trưởng hỗ trợ định giá.\n\n" <>
                "**Price Target Status**: Available\n\n**Price Target**: 77000\n\n" <>
                "**Price Target Currency**: VND\n\n" <>
                "**Price Target Rationale**: Dựa trên tăng trưởng lợi nhuận.\n\n" <>
                "**Price Target Unavailable Reason**: Unavailable\n\n" <>
                "**Time Horizon**: 3-6 months"

            "trading.plan" ->
              "**Action**: Buy\n\n**Reasoning**: Định giá hỗ trợ giao dịch.\n\n" <>
                "**Entry Price**: 70700\n\n**Stop Loss**: 66500\n\n" <>
                "**Position Sizing**: 3-5% danh mục"

            _ ->
              "Nội dung #{section}"
          end

        {section, %{"status" => "complete", "text" => text}}
      end)

    report = %{
      "schema_version" => 2,
      "content_kind" => "full_report_v1",
      "report_schema" => "full_report_v1",
      "source" => batch.source,
      "ticker" => item.ticker,
      "analysis_date" => Date.to_iso8601(batch.analysis_date),
      "cutoff" =>
        batch.cutoff_at |> DateTime.shift_zone!("Asia/Ho_Chi_Minh") |> DateTime.to_iso8601(),
      "source_updated_at" => "2026-08-25T03:00:00+00:00",
      "liquidity_rank" => item.liquidity_rank,
      "research_mode" => batch.research_mode,
      "data_provenance" => batch.metadata["data_provenance"],
      "identity_hash" => item.identity_hash,
      "parent_identity_hash" => item.parent_identity_hash,
      "expected_digest_hash" => item.expected_digest_hash,
      "full_report_hash" => FullReportEnvelope.canonical_sha256(sections),
      "pipeline_version" => "gx_full_v1",
      "prompt_fingerprint" => String.duplicate("d", 64),
      "model_fingerprint" => String.duplicate("e", 64),
      "evidence_fingerprint" => String.duplicate("f", 64),
      "execution_generation" => item.execution_generation,
      "contains_decision_content" => true,
      "status" => "complete",
      "stage_status" => stage_status,
      "stage_fingerprints" => stage_fingerprints,
      "sections" => sections
    }

    decision = %{
      "schema_version" => 1,
      "status" => "complete",
      "warnings" => [],
      "portfolio" => %{
        "rating" => "Overweight",
        "executive_summary" => "Tích lũy dần.",
        "investment_thesis" => "Tăng trưởng hỗ trợ định giá.",
        "time_horizon" => "3-6 months",
        "price_target_status" => "available",
        "price_target" => 77_000,
        "price_target_currency" => "VND",
        "price_target_rationale" => "Dựa trên tăng trưởng lợi nhuận.",
        "price_target_unavailable_reason" => nil
      },
      "trading" => %{
        "action" => "Buy",
        "reasoning" => "Định giá hỗ trợ giao dịch.",
        "entry_price" => 70_700,
        "stop_loss" => 66_500,
        "position_sizing" => "3-5% danh mục"
      }
    }

    document_id =
      "digest_" <>
        FullReportEnvelope.canonical_sha256([
          report["source"],
          report["ticker"],
          report["analysis_date"],
          report["cutoff"]
        ])

    %{
      "data" => %{
        "document_id" => document_id,
        "canonical_report_sha256" => FullReportEnvelope.canonical_sha256(report),
        "decision_sha256" => FullReportEnvelope.canonical_sha256(decision),
        "report" => report,
        "decision" => decision
      }
    }
  end

  defp full_report_expected(batch, item, response) do
    %{
      source: batch.source,
      ticker: item.ticker,
      analysis_date: batch.analysis_date,
      cutoff_at: batch.cutoff_at,
      liquidity_rank: item.liquidity_rank,
      research_mode: batch.research_mode,
      data_provenance: batch.metadata["data_provenance"],
      identity_hash: item.identity_hash,
      parent_identity_hash: item.parent_identity_hash,
      expected_digest_hash: item.expected_digest_hash,
      execution_generation: item.execution_generation,
      full_report_hash: response["data"]["report"]["full_report_hash"]
    }
  end

  defp rehash_decision(response) do
    put_in(
      response,
      ["data", "decision_sha256"],
      FullReportEnvelope.canonical_sha256(response["data"]["decision"])
    )
  end

  defp full_fixture(opts \\ []) do
    suffix = System.unique_integer([:positive])

    universe =
      %UniverseSnapshot{}
      |> UniverseSnapshot.changeset(%{
        analysis_date: ~D[2026-08-25],
        slot: "adhoc-full-#{suffix}",
        cutoff_at: ~U[2026-08-25 02:00:00Z],
        member_limit: 1,
        member_count: 1,
        status: "complete",
        frozen: true,
        fingerprint: String.duplicate("1", 64)
      })
      |> Repo.insert!()

    %UniverseMember{}
    |> UniverseMember.changeset(%{
      universe_snapshot_id: universe.id,
      ticker: "SSI",
      exchange: "HOSE",
      rank: 1,
      adtv20: "100",
      adv20: "10"
    })
    |> Repo.insert!()

    batch =
      %ResearchBatch{}
      |> ResearchBatch.changeset(%{
        analysis_date: ~D[2026-08-25],
        cutoff_at: ~U[2026-08-25 02:00:00Z],
        batch_type: "adhoc",
        research_mode: "live",
        analysis_depth: "full",
        source: "tradingagents_adhoc_research",
        idempotency_key_hash:
          :crypto.hash(:sha256, "fixture-#{suffix}") |> Base.encode16(case: :lower),
        status: "researching",
        target_count: 1,
        sla_ready_count: 1,
        sla_status: "not_applicable",
        universe_snapshot_id: universe.id,
        metadata: %{
          "requested_tickers" => ["SSI"],
          "data_provenance" => "request_cutoff"
        }
      })
      |> Repo.insert!()

    research_item =
      %ResearchItem{}
      |> ResearchItem.changeset(%{
        research_batch_id: batch.id,
        ticker: "SSI",
        liquidity_rank: 1,
        status: "partial",
        llm_status: "partial",
        rag_status: "ready",
        identity_hash: String.duplicate("a", 64),
        digest_hash: String.duplicate("b", 64)
      })
      |> Repo.insert!()

    assert {:ok, full} = FullAnalysis.ensure_for_research_batch(batch)
    item = Repo.get_by!(FullAnalysisItem, research_item_id: research_item.id)

    item =
      item
      |> FullAnalysisItem.changeset(%{
        status: Keyword.get(opts, :item_status, "running"),
        parent_identity_hash: research_item.identity_hash,
        expected_digest_hash: research_item.digest_hash,
        identity_hash: String.duplicate("c", 64)
      })
      |> Repo.update!()

    FullAnalysis.refresh_batch(full.id)

    {batch, research_item, Repo.get!(GxPortfolioIntelligence.Schemas.FullAnalysisBatch, full.id),
     item}
  end
end
