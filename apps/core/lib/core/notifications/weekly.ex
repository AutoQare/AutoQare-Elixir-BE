defmodule Core.Notifications.Weekly do
  @moduledoc """
  The weekly summary and the weekly report (AQ-10B §5.1 A13, §5.3 L9,
  QP10b-13), run by `Core.Workers.WeeklyScan` through
  `Core.Notifications.Scans.weekly/1`:

  - `account.weekly_summary`, Monday at the person's digest time: staff
    read "Your week: 12 applications, 3 responses, 1 interview" — the
    applications they made, the responses those had, the interviews on
    the leads they own; a team lead reads "Your team's week: …" over their
    teams' leads, a line per team;
  - `leads.weekly_report`, Monday 09:00 in the customer's zone: "Your
    week: 8 applications, 2 replies, 1 interview" over their leads, and
    the meetings ahead; replies count only where a team lets the customer
    see conversations; a customer with no portal login gets it by mail
    (QP10b-2).

  **The numbers are the dashboards'** (AQ-11 QP11-12): `Core.Dashboards.week/4`
  counts the calendar week before that Monday in the organisation's zone
  exactly as the tiles count *this week*, so an email and a tile never
  disagree. Nothing to say (all three zero), nothing sent. Idempotent:
  each is ensured by its week's dedupe key (the local Monday's date).
  """

  alias Core.Access.Grants
  alias Core.Dashboards
  alias Core.Dashboards.Windows
  alias Core.Notifications
  alias Core.Notifications.{CustomerMail, Digest}
  alias Data.Notifications.Scans, as: Store
  alias Data.Scope
  alias Data.Teams

  @report_at ~T[09:00:00]

  @doc "The summary and the report for whoever is due at `now`: `%{told, mailed}`."
  @spec run(DateTime.t()) :: map()
  def run(%DateTime{} = now) do
    people = Data.Notifications.weekly_candidates_for_system()

    staff =
      for p <- people, is_nil(p.customer_id), {:due, date} <- [due(p.digest_time, p.zone, now)] do
        summary(p.user_id, date, now)
      end

    customers =
      for p <- people,
          p.customer_id,
          {:due, date} <- [due(@report_at, p.customer_zone || p.zone, now)] do
        report_for_user(p, date, now)
      end

    mailed =
      for c <- Store.customers_without_login(),
          {:due, date} <- [due(@report_at, c.timezone, now)] do
        report_by_mail(c, date, now)
      end

    told = List.flatten(staff ++ customers)
    :ok = Notifications.send_events(told)
    %{told: length(told), mailed: Enum.count(mailed, &(&1 == :written))}
  end

  defp due(at, zone, now), do: Digest.due(at, zone, now, :weekly)

  defp summary(user_id, date, now) do
    with %{} = user <- Data.Accounts.get_user(user_id),
         scope = Grants.scope_for(user),
         org when is_binary(org) <- Scope.organisation_id(scope),
         {title, body} = summary_words(scope, date, now),
         false <- quiet?(title) do
      tell(org, user_id, "account.weekly_summary", now,
        title: title,
        body: body,
        link: "/leads",
        dedupe: "weekly_summary:#{user_id}:#{date}"
      )
    else
      _nobody_or_nothing -> []
    end
  end

  defp summary_words(scope, monday, now) do
    case for(id <- Scope.team_ids(scope), Scope.team_role(scope, id) == :lead, do: id) do
      [] ->
        mine = Dashboards.week(scope, {:person, Scope.user_id(scope)}, monday, now)
        {"Your week: " <> counts(mine), ahead(mine)}

      led ->
        per_team = team_counts(scope, led, monday, now)
        total = per_team |> Enum.map(&elem(&1, 1)) |> sum()
        lines = Enum.map(per_team, fn {team, c} -> "#{team.name}: #{counts(c)}" end)
        {"Your team's week: " <> counts(total), Enum.join(lines ++ List.wrap(ahead(total)), "\n")}
    end
  end

  defp team_counts(scope, team_ids, monday, now) do
    for team_id <- team_ids, team = Teams.get(Scope.organisation_id(scope), team_id), team do
      {team, Dashboards.week(scope, {:team, [team_id]}, monday, now)}
    end
  end

  defp report_for_user(p, date, now) do
    with %{} = customer <- Data.Customers.get_by_user(p.user_id),
         {title, body} = report_words(customer, date, now),
         false <- quiet?(title) do
      tell(customer.organisation_id, p.user_id, "leads.weekly_report", now,
        title: title,
        body: body,
        link: "/applications",
        dedupe: "weekly_report:#{customer.id}:#{date}"
      )
    else
      _nobody_or_nothing -> []
    end
  end

  defp report_by_mail(customer, date, now) do
    {title, body} = report_words(customer, date, now)

    if quiet?(title),
      do: :none,
      else:
        CustomerMail.write(
          customer,
          %{
            kind: "leads.weekly_report",
            subject: title,
            text: body || "Your team keeps going this week.",
            dedupe: "weekly_report:#{customer.id}:#{date}"
          },
          now
        )
  end

  # Replies count only where one of the customer's teams lets them see
  # conversations (AQ-08 QP8-5), the employers' replies on their leads there.
  defp report_words(customer, monday, now) do
    scope = Scope.system(Data.Organisations.get(customer.organisation_id))
    who = {:customer, customer.id}
    week = Dashboards.week(scope, who, monday, now)
    customer = Data.Customers.fill(customer)

    open =
      for {id, s} <- Teams.settings_for(customer.team_ids), s.customer_sees_conversations, do: id

    last_week = Windows.window(Date.add(monday, -7), Date.add(monday, -1), Dashboards.zone(scope))
    c = Map.put(week, :replies, Dashboards.replies(scope, who, open, last_week))
    {"Your week: " <> counts(c, :customer), ahead(c)}
  end

  defp counts(c, reader \\ :staff) do
    answers =
      if reader == :customer,
        do: plural(c.replies, "reply", "replies"),
        else: plural(c.responses, "response")

    Enum.join(
      [plural(c.applications, "application"), answers, plural(c.interviews, "interview")],
      ", "
    )
  end

  defp ahead(%{upcoming: 0}), do: nil
  defp ahead(%{upcoming: n}), do: "Next: #{plural(n, "meeting")} in the week ahead."

  defp sum(list) do
    Enum.reduce(list, %{applications: 0, responses: 0, interviews: 0, upcoming: 0}, fn c, acc ->
      Map.merge(acc, c, fn _k, a, b -> a + b end)
    end)
  end

  defp quiet?(title), do: title =~ ~r/: 0 \w+, 0 \w+, 0 \w+$/

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
  defp plural(1, word, _plural), do: "1 #{word}"
  defp plural(n, _word, plural), do: "#{n} #{plural}"

  defp tell(organisation_id, user_id, kind, now, opts) do
    {:ok, row} =
      Notifications.ensure(
        Scope.system(%{id: organisation_id}),
        %{
          organisation_id: organisation_id,
          user_id: user_id,
          notification_kind_key: kind,
          title: opts[:title],
          body: opts[:body],
          link_path: opts[:link],
          dedupe_key: opts[:dedupe]
        },
        now
      )

    if row.is_new,
      do: [Core.Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
      else: []
  end
end
