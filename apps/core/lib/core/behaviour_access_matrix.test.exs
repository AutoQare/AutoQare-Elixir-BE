defmodule Core.BehaviourAccessMatrixTest do
  @moduledoc """
  AQ-10 §4, cell by cell: every chair of the cast × five subjects ×
  `read · observe · watch · forget` (`Core.Access.Behaviour.actions/0`).
  Staff of a team that touches the subject (its jobs, leads or
  conversations) see, log and watch it; only its team leads and the
  system admin forget (403 `forget_not_allowed` for the rest who see it);
  customers never; another team, another organisation, nothing. The
  team's `peer_*` levels don't change it. Then a watch: its owner's own,
  another person's not found, the system admin's view included; and the
  same answers through the contexts.

  The subjects: S1 Corvid (a company on a Backend job), S2 Bamboo (a
  company on a Frontend job), S3 Mei (a contact on a Backend lead), S4
  Omar (a contact in a Frontend conversation), S5 another organisation's
  company.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Behaviour, as: BehaviourAccess
  alias Core.Behaviour
  alias Core.Watches

  @actions BehaviourAccess.actions()
  @full %{ok: @actions}
  @staff %{ok: [:read, :observe, :watch], forget_not_allowed: [:forget]}
  @none %{not_found: @actions}

  @expected [
    {:dawud, %{s1: @full, s2: @full, s3: @full, s4: @full, s5: @none}},
    {:hira, %{s1: @full, s2: @full, s3: @full, s4: @full, s5: @none}},
    {:bilal, %{s1: @full, s2: @none, s3: @full, s4: @none, s5: @none}},
    {:fiza, %{s1: @staff, s2: @staff, s3: @staff, s4: @staff, s5: @none}},
    {:qasim, %{s1: @staff, s2: @none, s3: @staff, s4: @none, s5: @none}},
    {:muaz, %{s1: @staff, s2: @none, s3: @staff, s4: @none, s5: @none}},
    {:farah, %{s1: @none, s2: @staff, s3: @none, s4: @staff, s5: @none}},
    {:tanweer, %{s1: @none, s2: @none, s3: @none, s4: @none, s5: @none}},
    {:imran, %{s1: @none, s2: @none, s3: @none, s4: @none, s5: @none}},
    {:stranger, %{s1: @none, s2: @none, s3: @none, s4: @none, s5: @none}}
  ]

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    qasim = scope_for(c.qasim)
    hira = scope_for(c.hira)

    corvid = company_fixture(c.org, name: "Corvid Security")
    bamboo = company_fixture(c.org, name: "Bamboo Invest")
    _ = job_fixture(qasim, team: c.backend, company: corvid)
    _ = job_fixture(hira, team: c.frontend, company: bamboo)

    mei = contact_fixture(qasim, name: "Mei Chen")
    lead = lead_fixture(qasim, team: c.backend, profile: c.golang)
    {:ok, _} = Data.Contacts.link_lead(%{lead_id: lead.id, contact_id: mei.id, role: :recruiter})

    omar = contact_fixture(hira, name: "Omar Haddad")
    conv = conversation_fixture(hira, team: c.frontend)
    :ok = Data.Conversations.add_participant(conv.id, omar.id)

    other = organisation_fixture()
    other_team = team_fixture(other)
    outsider = member_fixture(other_team, :lead)
    foreign = company_fixture(other, name: "Elsewhere Ltd")
    _ = job_fixture(scope_for(outsider), team: other_team, company: foreign)

    subjects = %{
      s1: {c.org, :company, corvid.id},
      s2: {c.org, :company, bamboo.id},
      s3: {c.org, :contact, mei.id},
      s4: {c.org, :contact, omar.id},
      s5: {other, :company, foreign.id}
    }

    scopes = %{
      dawud: scope_for(c.dawud),
      hira: hira,
      bilal: scope_for(c.bilal),
      fiza: scope_for(c.fiza),
      qasim: qasim,
      muaz: scope_for(c.muaz),
      farah: scope_for(farah),
      tanweer: customer_scope_for(c.tanweer),
      imran: customer_scope_for(c.imran),
      stranger: scope_for(user_fixture())
    }

    Map.merge(c, %{subjects: subjects, scopes: scopes, outsider: outsider})
  end

  defp subject(c, key) do
    {org, kind, id} = Map.fetch!(c.subjects, key)
    {:behaviour, Behaviour.load(Data.Scope.system(org), kind, id)}
  end

  defp classify(:ok), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify({:error, :forget_not_allowed}), do: :forget_not_allowed

  defp check(c, scopes, who, expected) do
    scope = Map.fetch!(scopes, who)

    for {key, cells} <- expected, {outcome, actions} <- cells, action <- actions do
      got = Access.why_not(scope, action, subject(c, key))

      assert classify(got) == outcome,
             "#{who} #{action} #{key}: expected #{outcome}, got #{inspect(got)}"

      # The same through the context, which finds the row in the caller's organisation.
      {_org, kind, id} = Map.fetch!(c.subjects, key)

      assert classify(elem_ok(Behaviour.subject(scope, action, kind, id))) == outcome,
             "#{who} #{action} #{key} through Core.Behaviour.subject/4"
    end

    for {_key, cells} <- expected,
        do: assert(Enum.sort(Enum.flat_map(cells, &elem(&1, 1))) == Enum.sort(@actions))
  end

  defp elem_ok({:ok, _subject}), do: :ok
  defp elem_ok(error), do: error

  for {who, expected} <- @expected do
    test "#{who}", c do
      check(c, c.scopes, unquote(who), unquote(Macro.escape(expected)))
    end
  end

  test "the team's levels don't change who sees behaviour", c do
    for level <- [:hidden, :view, :edit], team <- [c.backend, c.frontend] do
      {:ok, _} =
        Data.Teams.put_settings(team.id, %{peer_jobs: level, peer_leads: level, peer_tasks: level})
    end

    scopes = %{fiza: scope_for(c.fiza), muaz: scope_for(c.muaz)}
    check(c, scopes, :fiza, %{s1: @staff, s3: @staff, s4: @staff})
    check(c, scopes, :muaz, %{s1: @staff, s2: @none})
  end

  test "a watch is its owner's own: another person's is not found, the system admin's view too",
       c do
    now = ~U[2026-11-14 10:00:00.000000Z]
    {_org, :company, corvid} = c.subjects.s1

    {:ok, {:created, w}} =
      Watches.create(c.scopes.fiza, %{"company_id" => corvid, "trigger" => "posts_job"}, now)

    row = Repo.get!(Data.Behaviour.Watch, w.id)
    assert Access.why_not(c.scopes.fiza, :update, {:watch, row}) == :ok

    for who <- [:dawud, :hira, :qasim, :tanweer, :stranger] do
      scope = Map.fetch!(c.scopes, who)
      assert Access.why_not(scope, :update, {:watch, row}) == {:error, :not_found}, "#{who}"
      assert Watches.update(scope, w.id, %{"paused" => true}, now) == {:error, :not_found}
      assert Watches.delete(scope, w.id) == {:error, :not_found}
    end

    assert {:ok, %{items: [_mine]}} = Watches.list(c.scopes.fiza, now)
    assert {:ok, %{items: []}} = Watches.list(c.scopes.dawud, now)
  end
end
