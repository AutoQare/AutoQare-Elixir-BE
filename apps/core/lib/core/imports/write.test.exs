defmodule Core.Imports.WriteTest do
  @moduledoc """
  The two other kinds of import (AQ-12 QP12-3) through the same steps: a
  job list into the pool (a Fiverr link keyed by the job's own id, a job
  the pool holds filled) and a recruiter list into contacts; a Status
  column placing an application by §3.3; and each undone.
  """

  use Core.CoreCase, async: true

  alias Core.Imports
  alias Data.Imports, as: Store

  @now ~U[2026-11-15 10:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{hira_scope: scope_for(c.hira), fiza_scope: scope_for(c.fiza)})
  end

  defp run(c, kind, csv, tabs \\ []) do
    {:ok, media, _target} =
      Core.Media.create(
        c.hira_scope,
        %{
          "media_kind" => "import",
          "content_type" => "text/csv",
          "byte_count" => byte_size(csv),
          "original_filename" => "list.csv"
        },
        "/media"
      )

    :ok = Core.Media.store(c.hira_scope, media.id, csv)
    {:ok, media} = Core.Media.confirm(c.hira_scope, media.id, %{}, @now)

    {:ok, import} =
      Imports.create(
        c.hira_scope,
        %{"team_id" => c.backend.id, "media_id" => media.id, "kind" => kind},
        @now
      )

    :ok = Imports.run_step(c.hira_scope, import.id, "read", @now)
    {:ok, _import} = Imports.update(c.hira_scope, import.id, %{"tabs" => tabs}, @now)
    :ok = Imports.run_step(c.hira_scope, import.id, "check", @now)
    {:ok, checked} = Imports.get(c.hira_scope, import.id, @now)
    {:ok, _import} = Imports.commit(c.hira_scope, import.id, @now)
    :ok = Imports.run_step(c.hira_scope, import.id, "commit", @now)
    {:ok, imported} = Imports.get(c.hira_scope, import.id, @now)
    {checked, imported}
  end

  defp undo(c, id) do
    {:ok, _import} = Imports.undo(c.hira_scope, id, @now)
    :ok = Imports.run_step(c.hira_scope, id, "undo", @now)
    {:ok, undone} = Imports.get(c.hira_scope, id, @now)
    undone
  end

  test "a job list: new jobs (Fiverr's keyed by its id), a held job filled; undone", c do
    held = job_fixture(c.fiza_scope, team: c.backend, url: "https://jobs.lever.co/acme/1")

    csv =
      "Job link,Job Title,Company,Salary\n" <>
        "https://www.fiverr.com/briefs/77,Logo for a bakery,,$50\n" <>
        "https://jobs.lever.co/acme/1,Backend,Acme,$90k\n" <>
        "https://wellfound.com/jobs/123-staff,Staff Engineer,Initech,\n" <>
        "https://wellfound.com/jobs/123,Staff Engineer,Initech,\n"

    {checked, imported} = run(c, "jobs", csv)

    assert %{"new" => 2, "update" => 1, "duplicate" => 1} = checked.counts
    assert %{"created" => 2, "updated" => 1} = imported.counts

    rows = Store.rows(imported.id)
    fiverr = Data.Jobs.get(c.org.id, Enum.find(rows, &(&1.row_number == 2)).job_id)
    assert fiverr.source == :fiverr and fiverr.origin == :import
    assert fiverr.canonical_key == "fiverr:job:" <> fiverr.id
    assert fiverr.source_url == "https://www.fiverr.com/briefs/77"

    held = Data.Jobs.reload(held)
    assert held.comp_text == "$90k" and held.company.name == "Acme"

    undone = undo(c, imported.id)
    assert %{"removed" => removed, "restored" => 2} = undone.counts
    assert removed >= 2
    assert Data.Jobs.get(c.org.id, fiverr.id) == nil
    assert Data.Jobs.reload(held).comp_text == nil
  end

  test "a recruiter list: contacts made by handle, one known filled; undone", c do
    {:ok, {:created, known}} =
      Core.Contacts.create(
        c.fiza_scope,
        %{
          "name" => "Mei Chen",
          "handles" => [%{"kind" => "email", "value" => "mei@initech.example"}]
        },
        @now
      )

    csv =
      "Name,Title,Email,LinkedIn\n" <>
        "Omar Haddad,Recruiter,omar@acme.example,https://www.linkedin.com/in/omar-h\n" <>
        "Mei Chen,Talent Partner,MEI@initech.example,\n" <>
        "Omar H.,,omar@acme.example,\n" <>
        ",,nobody@x.example,\n"

    {checked, imported} = run(c, "contacts", csv)

    assert %{"new" => 1, "update" => 1, "duplicate" => 1, "error" => 1} = checked.counts
    assert %{"created" => 1, "updated" => 1} = imported.counts
    assert Data.Contacts.get(c.org.id, known.id).title == "Talent Partner"

    [omar] = Data.Contacts.by_handles(c.org.id, [{:email, "omar@acme.example"}])
    assert omar.source == :import

    undo(c, imported.id)
    assert Data.Contacts.get(c.org.id, omar.id) == nil
    assert Data.Contacts.get(c.org.id, known.id).title == nil
  end

  test "a Status column places the application by §3.3, dated at the applied day", c do
    csv =
      "Date,Job link,Job Title,Status\n" <>
        "01/03/2025,https://www.linkedin.com/jobs/view/501,Go Developer,Interviewing\n" <>
        "02/03/2025,https://www.linkedin.com/jobs/view/502,Go Developer,Rejected\n"

    tabs = [%{"name" => "list", "profile_id" => c.golang.id, "applier_user_id" => c.qasim.id}]
    {_checked, imported} = run(c, "applications", csv, tabs)
    [first, second] = Store.rows(imported.id)

    interviewing = Data.Leads.get(c.org.id, first.lead_id)
    assert interviewing.state == :in_progress and interviewing.stage.kind == :interview

    rejected = Data.Leads.get(c.org.id, second.lead_id)
    assert rejected.state == :done and rejected.outcome == :rejected
    assert rejected.finished_at == rejected.applied_at

    events = Data.Retention.all_events(interviewing.id)
    assert Enum.map(events, & &1.kind) == [:applied, :stage_moved]
    assert Enum.all?(events, &(&1.actor_kind == :import and &1.actor_user_id == c.qasim.id))
  end
end
