defmodule Core.Jobs.AlertsTest do
  @moduledoc """
  AQ-12 §7, §11.4 through the intake (`Core.Inbound.dev/3`): a forwarded
  LinkedIn or Indeed alert becomes pool jobs in every team serving the
  receiving profile's customer — `origin: email`, `origin_kind: alert`,
  the profile named — a job already there left alone, nothing landed in
  triage, the log row counting the jobs; the same alert again gives
  nothing; the pool's `origin_kind` filter and `alert` chip; the daily
  sweep archiving alert jobs nobody saved after 14 days, run twice.
  """

  use Core.CoreCase, async: true

  import Ecto.Query

  alias Core.Inbound
  alias Core.Jobs.{Alerts, Pool}
  alias Core.Workers.AlertSweep
  alias Data.Inbound.InboundMessage
  alias Data.Jobs.Job
  alias Data.Scope

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)

    # Ayesha is served by both squads; her Gmail is her *Go platform*'s.
    ayesha = customer_fixture(c.org, [c.backend, c.frontend], display_name: "Ayesha")
    profile = profile_fixture(ayesha, title: "Go platform", owners: [c.fiza])
    channel = channel_fixture(ayesha, kind: :email, handle: "ayesha@example.com", label: "Gmail")
    :ok = Data.Profiles.put_channels(profile, [channel.id])

    # Already in the Backend squad's pool: the alert leaves it alone.
    held =
      job_fixture(fiza,
        team: c.backend,
        title: "Backend Developer (Go) — kept",
        url: "https://www.linkedin.com/jobs/view/4012233999"
      )

    Map.merge(c, %{
      fiza_scope: fiza,
      ayesha: ayesha,
      profile: profile,
      channel: Data.Channels.reload(channel),
      held: held
    })
  end

  defp eml(name), do: File.read!(Path.expand("../../../priv/eml/" <> name, __DIR__))

  defp deliver(c, raw, now \\ @now),
    do:
      Inbound.dev(
        Scope.system(),
        %{"to" => Inbound.address(c.channel.inbound_token), "eml" => raw},
        now
      )

  defp alert_jobs(team_id) do
    Repo.all(
      from(j in Job,
        where: j.team_id == ^team_id and j.origin_kind == :alert,
        order_by: j.canonical_key
      )
    )
  end

  test "LinkedIn's alert: a job per team serving the customer, one already there left alone, nothing in triage",
       c do
    assert {:ok, %{outcome: :landed, alert_jobs: 5, message_id: nil, conversation_id: nil}} =
             deliver(c, eml("linkedin-alert.eml"))

    backend = alert_jobs(c.backend.id)
    frontend = alert_jobs(c.frontend.id)

    assert Enum.map(backend, & &1.canonical_key) == ~w(linkedin:4012233871 linkedin:4012234111)

    assert Enum.map(frontend, & &1.canonical_key) ==
             ~w(linkedin:4012233871 linkedin:4012233999 linkedin:4012234111)

    corvid = hd(backend) |> Repo.preload(:company)

    assert %{
             origin: :email,
             origin_kind: :alert,
             source: :linkedin,
             source_url: "https://www.linkedin.com/jobs/view/4012233871",
             title: "Senior Golang Engineer",
             workplace: :remote,
             created_by_user_id: nil
           } = corvid

    assert corvid.origin_profile_id == c.profile.id
    assert corvid.company.name == "Corvid Security"

    juniper = Enum.find(frontend, &(&1.canonical_key == "linkedin:4012233999"))

    assert juniper.workplace == :hybrid and
             juniper.onsite_locations == ["Karachi, Sindh, Pakistan"]

    kept = Data.Jobs.reload(c.held)
    assert kept.origin == :manual and kept.title == "Backend Developer (Go) — kept"

    # Read, not landed: no conversation, nothing in triage.
    assert Repo.aggregate(Data.Conversations.Conversation, :count) == 0

    assert [%InboundMessage{outcome: :landed, alert_jobs: 5, channel_id: channel_id}] =
             Repo.all(InboundMessage)

    assert channel_id == c.channel.id
  end

  test "the same alert again — by another route, same Message-ID — gives nothing", c do
    {:ok, %{alert_jobs: 5}} = deliver(c, eml("linkedin-alert.eml"))

    again = "X-Forwarded-For: tanweer@example.com\r\n" <> eml("linkedin-alert.eml")
    assert {:ok, %{outcome: :duplicate, alert_jobs: 0}} = deliver(c, again)

    assert length(alert_jobs(c.backend.id)) == 2
    assert Repo.aggregate(InboundMessage, :count) == 2
  end

  test "Indeed's alert: its jobs by their jk, the money left to the extension's read", c do
    assert {:ok, %{outcome: :landed, alert_jobs: 4}} = deliver(c, eml("indeed-alert.eml"))

    [bluefin, acme] = alert_jobs(c.backend.id)
    assert bluefin.canonical_key == "indeed:0a1b2c3d4e5f6a7b"
    assert bluefin.title == "Golang Backend Engineer" and bluefin.workplace == :remote
    assert acme.source_url == "https://www.indeed.com/viewjob?jk=5f2b1c9d8e7a6b5c"
    assert acme.workplace == :remote and is_nil(acme.comp_min_minor)
  end

  test "the pool: `origin_kind` filters to the alert's jobs, each row with its chip", c do
    {:ok, _answer} = deliver(c, eml("linkedin-alert.eml"))
    scope = scope_for(c.hira)

    {:ok, %{items: rows}} =
      Pool.list(
        scope,
        %{"team_id" => c.backend.id, "$where" => %{"origin_kind" => %{"$EQUAL" => "alert"}}},
        @now
      )

    assert length(rows) == 2

    for row <- rows do
      assert row.origin_kind == :alert

      assert row.alert == %{
               profile: %{id: c.profile.id, title: "Go platform", customer_name: "Ayesha"}
             }
    end

    {:ok, %{items: all}} = Pool.list(scope, %{"team_id" => c.backend.id}, @now)
    held = Enum.find(all, &(&1.id == c.held.id))
    assert held.origin_kind == nil and held.alert == nil
  end

  test "the sweep: alert jobs nobody saved, archived after 14 days; a saved one stays; twice is once",
       c do
    {:ok, _answer} = deliver(c, eml("linkedin-alert.eml"))
    [saved | _rest] = alert_jobs(c.backend.id)
    _lead = lead_fixture(c.fiza_scope, job: saved, profile: c.profile)

    assert Alerts.sweep(Scope.system(), DateTime.add(@now, 13, :day)) == 0
    assert Alerts.sweep(Scope.system(), DateTime.add(@now, 15, :day)) == 4
    assert Alerts.sweep(Scope.system(), DateTime.add(@now, 16, :day)) == 0

    assert Data.Jobs.reload(saved).archived_at == nil
    assert Data.Jobs.reload(c.held).archived_at == nil

    swept =
      Enum.reject(alert_jobs(c.backend.id) ++ alert_jobs(c.frontend.id), &(&1.id == saved.id))

    assert Enum.all?(swept, &(&1.archived_at == DateTime.add(@now, 15, :day)))

    audit =
      Repo.one(
        from(a in Data.Audit.AuditEvent,
          where: a.subject_id == ^hd(swept).id and a.action == "archived"
        )
      )

    assert audit.after["reason"] == "An alert job nobody saved"
  end

  test "the worker runs the sweep and is idempotent", c do
    # Delivered now, by the real clock the worker reads: too young to sweep.
    {:ok, _answer} = deliver(c, eml("linkedin-alert.eml"), DateTime.utc_now())
    assert :ok = AlertSweep.perform(%Oban.Job{args: %{}})
    assert :ok = AlertSweep.perform(%Oban.Job{args: %{}})
    assert Enum.all?(alert_jobs(c.backend.id), &is_nil(&1.archived_at))
  end
end
