defmodule Core.Jobs.LinkTest do
  @moduledoc """
  A new job's identity (`Core.Jobs.Link`), and AQ-12 §11.4's Fiverr job by
  hand: `POST /jobs` with `source: fiverr` takes `origin_kind` (required)
  and no `url`, keyed by its own id (`fiverr:job:{id}`), a brief's link
  kept; `origin_kind` on any other source is refused.
  """

  use Core.CoreCase, async: true

  alias Core.Jobs
  alias Core.Jobs.Link

  doctest Link

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.put(c, :scope, scope_for(c.fiza))
  end

  test "a Fiverr job without a link: keyed by its own id, origin_kind kept, no lead", c do
    params = %{
      "team_id" => c.backend.id,
      "source" => "fiverr",
      "origin_kind" => "inquiry",
      "title" => "Logo animation for a café"
    }

    assert {:ok, sheet} = Jobs.create(c.scope, params, @now)

    assert %{source: :fiverr, source_url: nil, origin_kind: :inquiry, origin: :manual} = sheet
    assert sheet.canonical_key == "fiverr:job:" <> sheet.id
    assert sheet.leads == [] and sheet.alert == nil

    brief = Map.merge(params, %{"origin_kind" => "brief", "url" => "fiverr.com/briefs/88213"})
    assert {:ok, kept} = Jobs.create(c.scope, brief, @now)
    assert kept.source_url == "https://fiverr.com/briefs/88213" and kept.origin_kind == :brief
  end

  test "the refusals: no origin_kind, one off the list, one on another source, a bad link", c do
    base = %{"team_id" => c.backend.id, "source" => "fiverr", "title" => "Gig"}

    assert {:error, {:missing, [:origin_kind]}} = Jobs.create(c.scope, base, @now)

    assert {:error, {:invalid, %{"origin_kind" => _}}} =
             Jobs.create(c.scope, Map.put(base, "origin_kind", "alert"), @now)

    assert {:error, {:invalid, %{"url" => _}}} =
             Jobs.create(
               c.scope,
               Map.merge(base, %{"origin_kind" => "order", "url" => "javascript:alert(1)"}),
               @now
             )

    linked = %{
      "team_id" => c.backend.id,
      "url" => "https://www.linkedin.com/jobs/view/77",
      "title" => "Go Developer",
      "origin_kind" => "brief"
    }

    assert {:error, {:invalid, %{"origin_kind" => ["is only for a Fiverr job"]}}} =
             Jobs.create(c.scope, linked, @now)

    assert {:error, {:missing, [:url]}} =
             Jobs.create(c.scope, Map.drop(linked, ["url", "origin_kind"]), @now)
  end
end
