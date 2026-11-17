defmodule Core.ImportsTest do
  @moduledoc """
  The import centre end to end (AQ-12 §11.4) on a sheet in the team's own
  15 columns: the read and the guessed mapping, the dry run's counts with
  every planted case, the import (credited to whoever applied, dated in
  the past, telling nobody), and the undo with an edited lead kept and the
  filled fields put back. Then who may, the 409s, and the steps run twice.
  """

  use Core.CoreCase, async: true

  import Ecto.Query

  alias Core.Dashboards.Rules
  alias Core.Imports
  alias Core.Storage.Content
  alias Data.Imports, as: Store
  alias Data.Leads.Event

  @now ~U[2026-11-15 10:00:00.000000Z]

  @header "Sr #,Date,Job Title,Job link,Company,Country,Stack,WORLDWIDE,Recruiter LinkedIn," <>
            "Recruiter Email,Applied By,Company Type,Personal Email,Salary Quoted,Platform"

  # Row 2: old, made new, No response; row 3: the day/month trap, a link
  # with tracking parameters; row 4: row 2 again after link cleanup; row 5:
  # an existing lead whose job lacks a company and a salary; row 6: an
  # existing lead with nothing to fill; row 7: "Fazia"; row 8: 31/02/2024;
  # row 9: an unknown stack, "direct" (the tab's applier), recent.
  @rows [
    "1,09/10/2024,Backend Developer,https://www.linkedin.com/jobs/view/4000000001/,Acme,Pakistan," <>
      "\"Go, PostgreSQL\",No,https://www.linkedin.com/in/sara-khan,sara@acme.example,Fiza,Product," <>
      "sara.k@gmail.example,3000 USD a month,LinkedIn",
    "2,10/9/2026,Elixir Engineer,https://jobs.lever.co/initech/9f1c-22?lever-source=linkedin&utm_campaign=x," <>
      "Initech,,Elixir,Yes,,,Qasim,Startup,,,Lever",
    "3,12/10/2024,Go Developer,https://www.linkedin.com/jobs/view/4000000001?trk=public_jobs,Acme,,,,,," <>
      "Fiza,,,,LinkedIn",
    "4,01/08/2024,Platform Engineer,https://www.linkedin.com/jobs/view/4000000099,Hooli,,,,,,Fiza,,,$40/h,",
    "5,02/08/2024,Data Engineer,https://www.linkedin.com/jobs/view/4000000098,,,,,,,Fiza,,,,",
    "6,03/08/2024,Rust Developer,https://www.linkedin.com/jobs/view/4000000200,Umbrella,,,,,,Fazia,,,,",
    "7,31/02/2024,Ruby Developer,https://www.linkedin.com/jobs/view/4000000300,Wayne,,,,,,Fiza,,,,",
    "8,05/11/2026,Go Engineer,https://www.linkedin.com/jobs/view/4000000400,Stark,,\"Go, Haskell\",,,," <>
      "direct,,,,LinkedIn",
    ",,,,,,,,,,,,,,"
  ]

  setup do
    c = board_cast_fixture()
    hira = scope_for(c.hira)
    fiza = scope_for(c.fiza)

    for name <- ~w(Go PostgreSQL Elixir), do: skill_fixture(c.org, name: name)

    held =
      job_fixture(fiza, team: c.backend, url: "https://www.linkedin.com/jobs/view/4000000099")

    quiet =
      job_fixture(fiza, team: c.backend, url: "https://www.linkedin.com/jobs/view/4000000098")

    fill_me =
      lead_fixture(fiza,
        job: held,
        profile: c.golang,
        as: :apply,
        applied_at: ~U[2024-08-01 07:00:00Z]
      )

    as_is =
      lead_fixture(fiza,
        job: quiet,
        profile: c.golang,
        as: :apply,
        applied_at: ~U[2024-08-02 07:00:00Z]
      )

    Map.merge(c, %{hira_scope: hira, fiza_scope: fiza, fill_me: fill_me, as_is: as_is, held: held})
  end

  defp csv(rows \\ @rows), do: Enum.join([@header | rows], "\r\n") <> "\r\n"

  defp upload(
         scope,
         bytes,
         name \\ "Fiza_Applications_2024.csv",
         type \\ "text/csv",
         kind \\ "import"
       ) do
    {:ok, media, _target} =
      Core.Media.create(
        scope,
        %{
          "media_kind" => kind,
          "content_type" => type,
          "byte_count" => byte_size(bytes),
          "original_filename" => name
        },
        "/media"
      )

    :ok = Core.Media.store(scope, media.id, bytes)
    {:ok, media} = Core.Media.confirm(scope, media.id, %{}, @now)
    media
  end

  defp started(c, bytes \\ csv()) do
    media = upload(c.hira_scope, bytes)

    {:ok, import} =
      Imports.create(
        c.hira_scope,
        %{"team_id" => c.backend.id, "media_id" => media.id, "kind" => "applications"},
        @now
      )

    :ok = Imports.run_step(c.hira_scope, import.id, "read", @now)
    import.id
  end

  defp checked(c) do
    id = started(c)

    {:ok, _import} =
      Imports.update(
        c.hira_scope,
        id,
        %{
          "tabs" => [
            %{
              "name" => "Fiza_Applications_2024",
              "profile_id" => c.golang.id,
              "applier_user_id" => c.fiza.id
            }
          ]
        },
        @now
      )

    :ok = Imports.run_step(c.hira_scope, id, "check", @now)
    id
  end

  defp row(id, n), do: id |> Store.rows() |> Enum.find(&(&1.row_number == n))

  test "the read: one tab named after the file, its rows, the columns guessed", c do
    id = started(c)
    {:ok, import} = Imports.get(c.hira_scope, id, @now)

    assert import.state == :mapping
    assert [%{name: "Fiza_Applications_2024", rows: 8, include: true}] = import.tabs
    fields = Map.new(import.columns, &{&1.header, &1.field})

    assert fields == %{
             "Sr #" => "ignore",
             "Date" => "date",
             "Job Title" => "title",
             "Job link" => "job_url",
             "Company" => "company",
             "Country" => "country",
             "Stack" => "stack",
             "WORLDWIDE" => "worldwide",
             "Recruiter LinkedIn" => "recruiter_linkedin",
             "Recruiter Email" => "recruiter_email",
             "Applied By" => "applied_by",
             "Company Type" => "company_type",
             "Personal Email" => "recruiter_personal_email",
             "Salary Quoted" => "salary",
             "Platform" => "platform"
           }

    assert Enum.find(import.columns, &(&1.header == "Company")).sample == "Acme"
    assert import.can == %{map: true, commit: false, undo: false}
  end

  test "the dry run: every planted case, and nothing written", c do
    jobs_before = Repo.aggregate(Data.Jobs.Job, :count)
    id = checked(c)
    {:ok, import} = Imports.get(c.hira_scope, id, @now)

    assert import.state == :ready

    assert %{"new" => 3, "update" => 1, "duplicate" => 2, "error" => 2, "skipped" => 0} =
             import.counts

    assert Repo.aggregate(Data.Jobs.Job, :count) == jobs_before

    assert row(id, 3).values["date"] == "2026-09-10"
    assert row(id, 3).values["key"] == "lever:initech/9f1c-22"
    assert words(row(id, 4)) =~ "Same as row 2 after link cleanup."
    assert row(id, 5).result == :update
    assert words(row(id, 5)) =~ "Fills company, salary."
    assert row(id, 6).result == :duplicate
    assert words(row(id, 6)) =~ "Already applied with Tanweer · Golang backend on 2 Aug"
    assert row(id, 7).result == :error
    assert words(row(id, 7)) =~ "Unknown name “Fazia”. Fiza?"
    assert row(id, 8).result == :error
    assert words(row(id, 8)) =~ "31/02/2024 isn't a date."
    assert row(id, 9).result == :new
    assert words(row(id, 9)) =~ "Not in the skills list: Haskell."
    assert row(id, 9).values["applier_user_id"] == c.fiza.id
  end

  test "the import, then its undo with an edited lead kept and the fills put back", c do
    id = checked(c)
    notices_before = Repo.aggregate(Data.Notifications.Notification, :count)

    {:ok, %{state: :importing}} = Imports.commit(c.hira_scope, id, @now)
    :ok = Imports.run_step(c.hira_scope, id, "commit", @now)
    {:ok, import} = Imports.get(c.hira_scope, id, @now)

    assert import.state == :imported
    assert %{"created" => 3, "updated" => 1} = import.counts
    assert import.undo_until == DateTime.add(@now, 7, :day)
    assert import.can.undo

    assert Repo.aggregate(Data.Notifications.Notification, :count) == notices_before,
           inspect(Repo.all(from(n in Data.Notifications.Notification, select: n.title)))

    # Row 2: credited to Fiza, dated in its own past month, finished as No response.
    old = Data.Leads.get(c.org.id, row(id, 2).lead_id)
    assert old.applied_by_user_id == c.fiza.id
    assert old.owner_user_id == c.fiza.id
    assert old.applied_at == ~U[2024-10-09 07:00:00.000000Z]
    assert old.state == :done and old.outcome == :no_response
    assert old.finished_at == DateTime.add(old.applied_at, 14, :day)
    assert old.last_activity_at == @now
    assert old.job.origin == :import and old.job.company.name == "Acme"

    applied = Repo.one!(from(e in Event, where: e.lead_id == ^old.id and e.kind == :applied))
    assert applied.actor_kind == :import and applied.actor_user_id == c.fiza.id
    assert applied.note == "Imported from Fiza_Applications_2024.csv, row 2 · by Hira Khan"

    assert [%{contact: %{name: "Sara Khan"}}] = Data.Contacts.for_lead(old.id)

    rules = Rules.counting()
    window = %{oct: {~U[2024-10-01 00:00:00Z], ~U[2024-11-01 00:00:00Z]}}
    subject = %{organisation_id: c.org.id, actor_user_id: c.fiza.id}
    assert %{oct: %{count: 1}} = Data.Dashboards.applications(subject, window, rules)

    assert %{oct: %{count: 0}} =
             Data.Dashboards.applications(%{subject | actor_user_id: c.hira.id}, window, rules)

    # Row 9: recent, still In progress · Applied; edited after the import.
    recent = Data.Leads.get(c.org.id, row(id, 9).lead_id)
    assert recent.state == :in_progress
    note_fixture(c.fiza_scope, recent)

    # Row 5 filled the held job's blanks.
    held = Data.Jobs.reload(c.held)
    assert held.comp_text == "$40/h" and held.company.name == "Hooli"

    {:ok, %{state: :undoing}} = Imports.undo(c.hira_scope, id, DateTime.add(@now, 1, :day))
    :ok = Imports.run_step(c.hira_scope, id, "undo", DateTime.add(@now, 1, :day))
    {:ok, undone} = Imports.get(c.hira_scope, id, DateTime.add(@now, 1, :day))

    assert undone.state == :undone
    assert %{"removed" => 8, "restored" => 2, "kept" => 1} = undone.counts
    assert Data.Leads.get(c.org.id, old.id) == nil
    assert Data.Jobs.get(c.org.id, old.job_id) == nil
    assert Data.Leads.get(c.org.id, recent.id)
    assert Data.Leads.get(c.org.id, c.fill_me.id)
    assert words(row(id, 9)) =~ "Kept: changed since the import."

    held = Data.Jobs.reload(c.held)
    assert held.comp_text == nil and held.company_id == nil
    assert Data.Retention.fingerprints_on(c.org.id, ["linkedin:4000000001"]) == []

    assert {:error, {:import_not_undoable, %{state: :undone}}} =
             Imports.undo(c.hira_scope, id, DateTime.add(@now, 1, :day))
  end

  test "who may: the team's lead and the system admin; staff and another team's lead find nothing",
       c do
    id = started(c)
    other = team_fixture(c.org, name: "Design")
    stranger = member_fixture(other, :lead, user_fixture())

    assert {:ok, _import} = Imports.get(scope_for(c.dawud), id, @now)
    assert {:ok, _import} = Imports.get(scope_for(c.bilal), id, @now)
    assert {:error, :not_found} = Imports.get(c.fiza_scope, id, @now)
    assert {:error, :not_found} = Imports.get(scope_for(stranger), id, @now)
    assert {:error, :not_found} = Imports.list(c.fiza_scope, %{"team_id" => c.backend.id}, @now)
    assert {:error, :not_found} = Imports.commit(c.fiza_scope, id, @now)

    assert {:ok, %{items: [_one]}} =
             Imports.list(c.hira_scope, %{"team_id" => c.backend.id}, @now)
  end

  test "the console's way in: the sheet as an attachment; a mapping names only what was mapped",
       c do
    media = upload(c.hira_scope, csv(), "Fiza_Applications_2024.csv", "text/csv", "attachment")
    params = %{"team_id" => c.backend.id, "media_id" => media.id, "kind" => "applications"}
    {:ok, import} = Imports.create(c.hira_scope, params, @now)
    :ok = Imports.run_step(c.hira_scope, import.id, "read", @now)

    {:ok, read} = Imports.get(c.hira_scope, import.id, @now)
    assert Enum.find(read.columns, &(&1.header == "Job link")).field == "job_url"
    assert Enum.find(read.columns, &(&1.header == "Date")).field == "date"

    mapping = %{"Job link" => "job_url", "Job Title" => "title"}
    {:ok, _checking} = Imports.update(c.hira_scope, import.id, %{"mapping" => mapping}, @now)
    {:ok, mapped} = Imports.get(c.hira_scope, import.id, @now)
    assert Enum.find(mapped.columns, &(&1.header == "Job link")).field == "job_url"
    assert Enum.find(mapped.columns, &(&1.header == "Date")).field == "ignore"

    pdf = upload(c.hira_scope, "%PDF-1.4 a CV", "cv.pdf", "application/pdf", "attachment")

    assert {:error, {:invalid, %{"media_id" => _}}} =
             Imports.create(c.hira_scope, %{params | "media_id" => pdf.id}, @now)
  end

  test "the refusals: not ready, too large, unreadable, the undo run out", c do
    id = started(c)

    assert {:error, {:import_not_ready, %{state: :mapping}}} =
             Imports.commit(c.hira_scope, id, @now)

    many =
      for n <- 1..70,
          do: "#{n},01/01/2024,Job,https://www.linkedin.com/jobs/view/#{n},,,,,,,Fiza,,,,"

    media = upload(c.hira_scope, csv(many))
    params = %{"team_id" => c.backend.id, "media_id" => media.id, "kind" => "applications"}

    assert {:error, {:import_too_large, %{max_rows: 60}}} =
             Imports.create(c.hira_scope, params, @now)

    {:ok, {_name, zip}} = :zip.create(~c"x.zip", [{~c"xl/nothing.txt", "no workbook"}], [:memory])
    broken = upload(c.hira_scope, zip, "broken.xlsx", Content.xlsx())

    assert {:error, :import_unreadable} =
             Imports.create(c.hira_scope, %{params | "media_id" => broken.id}, @now)

    empty = upload(c.hira_scope, "\r\n \r\n", "empty.csv")

    {:ok, read} = Imports.create(c.hira_scope, %{params | "media_id" => empty.id}, @now)
    :ok = Imports.run_step(c.hira_scope, read.id, "read", @now)
    {:ok, failed} = Imports.get(c.hira_scope, read.id, @now)
    assert failed.state == :failed and failed.error_text =~ "no header row"

    assert {:error, {:invalid, %{"kind" => _}}} =
             Imports.create(c.hira_scope, %{params | "kind" => "companies"}, @now)

    id = checked(c)
    {:ok, _import} = Imports.commit(c.hira_scope, id, @now)
    :ok = Imports.run_step(c.hira_scope, id, "commit", @now)

    assert {:error, {:undo_expired, %{undo_until: _until}}} =
             Imports.undo(c.hira_scope, id, DateTime.add(@now, 8, :day))
  end

  test "the steps run twice do their work once", c do
    id = checked(c)
    :ok = Imports.run_step(c.hira_scope, id, "check", @now)
    {:ok, _import} = Imports.commit(c.hira_scope, id, @now)
    :ok = Imports.run_step(c.hira_scope, id, "commit", @now)
    leads = Repo.aggregate(Data.Leads.Lead, :count)
    :ok = Imports.run_step(c.hira_scope, id, "commit", @now)
    :ok = Imports.run_step(c.hira_scope, id, "read", @now)

    assert Repo.aggregate(Data.Leads.Lead, :count) == leads

    assert :ok =
             perform_job(Core.Workers.ImportStep, %{
               "import_id" => id,
               "step" => "commit",
               "user_id" => c.hira.id
             })
  end

  test "a row fixed in the preview is checked again; a skipped row stays skipped", c do
    id = checked(c)
    bad = row(id, 8)

    # The full cells, as the console sends them; a header left out is blank.
    cells = Map.put(bad.cells, "Date", "28/02/2024")
    {:ok, fixed} = Imports.edit_row(c.hira_scope, id, bad.id, %{"cells" => cells}, @now)

    assert fixed.result == :new
    assert fixed.cells == cells
    assert fixed.values["date"] == "2024-02-28"

    {:ok, skipped} = Imports.skip_row(c.hira_scope, id, row(id, 7).id, @now)
    assert skipped.result == :skipped

    {:ok, _import} = Imports.update(c.hira_scope, id, %{"date_order" => "day_month"}, @now)
    :ok = Imports.run_step(c.hira_scope, id, "check", @now)
    assert row(id, 7).result == :skipped

    {:ok, page} =
      Imports.rows(c.hira_scope, id, %{"$where" => %{"result" => %{"$EQUAL" => "new"}}})

    assert Enum.map(page.items, & &1.row_number) == [2, 3, 8, 9]

    assert {:error, {:invalid_filter, %{"colour" => _}}} =
             Imports.rows(c.hira_scope, id, %{"$where" => %{"colour" => "red"}})
  end

  defp words(row), do: Enum.map_join(row.reasons, " ", & &1["words"])

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
