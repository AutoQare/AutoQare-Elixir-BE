defmodule Core.Leads.NoticesTest do
  @moduledoc """
  AQ-10B §5.3 through the lead verbs: the lead taken from its owner, moves
  told to watchers, milestones only for true interview kinds (G8) with the
  team leads told, the customer's own *I applied*, a job closed or merged
  under open leads, a muted lead silent, and a milestone mailed to a
  customer with no portal login (QP10b-2).
  """

  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  import Ecto.Query

  alias Core.Leads
  alias Core.Leads.{Act, Change, Notices}
  alias Core.Notifications.LeadWatch
  alias Core.Notifications.Mutes
  alias Data.Notifications.{CustomerMails, LeadWatchers}

  @now ~U[2026-11-14 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()

    job =
      job_fixture(scope_for(c.fiza),
        team: c.backend,
        title: "Backend Developer",
        company: company_fixture(c.org, name: "Bamboo Invest")
      )

    Map.put(c, :job, job)
  end

  defp lead(c, profile \\ nil, as \\ "apply") do
    {:ok, sheet} =
      Leads.create(
        scope_for(c.fiza),
        %{"job_id" => c.job.id, "profile_id" => (profile || c.golang).id, "as" => as},
        @now
      )

    sheet
  end

  defp seen(sheet),
    do: %{"state" => to_string(sheet.state), "stage" => sheet.stage && sheet.stage.key}

  defp move(who, sheet, stage),
    do:
      Act.run(
        who,
        :move,
        sheet.id,
        %{"from" => seen(sheet), "state" => "in_progress", "stage" => stage},
        @now
      )

  defp told(user_id, kind) do
    from(n in Data.Notifications.Notification,
      where: n.user_id == ^user_id and n.notification_kind_key == ^kind,
      order_by: n.inserted_at
    )
    |> Repo.all()
  end

  test "handed on: the new owner is handed it, the previous owner told it was taken", c do
    sheet = lead(c)

    {:ok, _} =
      Change.assign(scope_for(c.hira), sheet.id, %{"owner_user_id" => c.qasim.id}, @now)

    assert [%{title: "Hira handed you “Backend Developer · Bamboo Invest”"}] =
             told(c.qasim.id, "leads.assigned")

    assert [%{title: "Hira handed “Backend Developer · Bamboo Invest” to Qasim."}] =
             told(c.fiza.id, "leads.taken")

    assert told(c.hira.id, "leads.taken") == []
  end

  test "a move tells the owner and the lead's watchers, never the actor", c do
    sheet = lead(c)
    :ok = LeadWatchers.watch(sheet.id, c.muaz.id, @now)
    :ok = LeadWatchers.watch(sheet.id, c.hira.id, @now)

    {:ok, _} = move(scope_for(c.hira), sheet, "recruiter_screen")

    assert [_] = told(c.fiza.id, "leads.moved")
    assert [%{title: "Hira moved " <> _}] = told(c.muaz.id, "leads.moved")
    assert told(c.hira.id, "leads.moved") == []
  end

  test "a true interview stage is a milestone: the customer emailed, the team leads told", c do
    sheet = lead(c)
    {:ok, _} = move(scope_for(c.fiza), sheet, "technical_1")

    assert [%{title: title}] = told(c.tanweer.user_id, "leads.customer_milestone")
    assert title =~ "Technical interview 1"

    for leader <- [c.hira, c.bilal] do
      assert [
               %{
                 title:
                   "Tanweer reached Technical interview 1 on “Backend Developer · Bamboo Invest”"
               }
             ] =
               told(leader.id, "leads.milestone_team")
    end

    assert told(c.fiza.id, "leads.milestone_team") == []
  end

  test "a custom stage anchored to an interview is not a milestone (G8)" do
    refute Notices.milestone?(%{}, {:stage, %{kind: :custom, anchor_kind: :interview}})
    assert Notices.milestone?(%{}, {:stage, %{kind: :ai_interview}})
    assert Notices.milestone?(%{}, {:stage, %{kind: :offer}})
    assert Notices.milestone?(%{}, {:outcome, :hired})
    refute Notices.milestone?(%{}, {:stage, %{kind: :screening}})
  end

  test "a customer with no portal login is mailed the milestone, once, and nothing else", c do
    sara_cv = profile_fixture(c.sara, title: "Sara's CV", owners: [c.fiza])
    sheet = lead(c, sara_cv)

    {:ok, moved} = move(scope_for(c.fiza), sheet, "technical_1")
    {:ok, _} = move(scope_for(c.fiza), moved, "technical_2")

    assert [first, second] = CustomerMails.for_customer(c.sara.id)
    assert first.kind_key == "leads.customer_milestone" and first.to_email == c.sara.email
    assert first.subject =~ "Technical interview 1"
    assert second.subject =~ "Technical interview 2"
    assert all_enqueued(worker: "Notifire.Workers.DeliveryWorker") != []
  end

  test "the customer's own I applied tells the profile's owners", c do
    sheet = lead(c, nil, "save")

    {:ok, _} =
      Act.portal_applied(customer_scope_for(c.tanweer), sheet.id, %{"from" => seen(sheet)}, @now)

    for owner <- [c.fiza, c.qasim] do
      assert [
               %{
                 title:
                   "Tanweer applied to “Backend Developer” at Bamboo Invest as “Golang backend”"
               }
             ] =
               told(owner.id, "leads.customer_applied")
    end
  end

  test "a job closed or merged under open leads tells their owners", c do
    sheet = lead(c)

    {:ok, _} =
      Core.Jobs.Act.close(
        scope_for(c.hira),
        c.job.id,
        %{"from" => "open", "reason" => "filled"},
        @now
      )

    assert [
             %{
               title:
                 "Hira closed “Backend Developer · Bamboo Invest”: your lead for Tanweer is still open"
             }
           ] =
             told(c.fiza.id, "leads.job_closed")

    other = job_fixture(scope_for(c.fiza), team: c.backend, title: "Go Engineer")
    {:ok, _} = Core.Jobs.Act.reopen(scope_for(c.hira), c.job.id, %{"from" => "closed"}, @now)

    {:ok, _} =
      Core.Jobs.Act.merge(scope_for(c.hira), c.job.id, %{"into_job_id" => other.id}, @now)

    # The survivor took the merged job's company (P3's fill).
    assert [%{title: "Hira merged a job into “Go Engineer · Bamboo Invest”", lead_id: lead_id}] =
             told(c.fiza.id, "leads.job_merged")

    assert lead_id == sheet.id
  end

  test "a muted lead writes no row for that person, except what §11.4 keeps", c do
    sheet = lead(c)
    :ok = Mutes.lead(scope_for(c.fiza), sheet.id, true, @now)

    {:ok, _} = move(scope_for(c.hira), sheet, "recruiter_screen")
    assert told(c.fiza.id, "leads.moved") == []

    :ok = Mutes.lead(scope_for(c.fiza), sheet.id, false, @now)
    {:ok, moved} = Leads.get(scope_for(c.hira), sheet.id, @now)
    {:ok, _} = move(scope_for(c.hira), moved, "assessment")
    assert [_] = told(c.fiza.id, "leads.moved")
  end

  test "the sheet carries watching, watchers_count and muted for the reader", c do
    sheet = lead(c)
    :ok = LeadWatch.set(scope_for(c.hira), sheet.id, true, @now)
    :ok = Mutes.lead(scope_for(c.hira), sheet.id, true, @now)

    {:ok, mine} = Leads.get(scope_for(c.hira), sheet.id, @now)
    assert %{watching: true, watchers_count: 1, muted: true} = mine

    {:ok, theirs} = Leads.get(scope_for(c.fiza), sheet.id, @now)
    assert %{watching: false, watchers_count: 1, muted: false} = theirs

    assert LeadWatch.set(customer_scope_for(c.tanweer), sheet.id, true, @now) ==
             {:error, :not_found}
  end
end
