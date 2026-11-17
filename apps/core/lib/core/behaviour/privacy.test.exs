defmodule Core.Behaviour.PrivacyTest do
  @moduledoc """
  AQ-10 §9, P10.5: the sweep takes observations past the organisation's
  retention and keeps the hour counts; a team lead's *Forget* takes a
  person's observations, counts and watches and marks them do-not-contact;
  *Forget its people* keeps the company's own history.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Behaviour
  alias Core.Behaviour.Privacy
  alias Data.Behaviour.{Observation, SubjectHour}

  @now ~U[2026-11-14 10:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{fs: scope_for(c.fiza), ext: %{scope_for(c.fiza) | via: :extension}})
  end

  defp observations,
    do: Repo.all(from(o in Observation, order_by: [asc: o.inserted_at, asc: o.id]))

  defp hours(column, id), do: Repo.all(from(h in SubjectHour, where: field(h, ^column) == ^id))

  defp count(column, id),
    do: column |> hours(id) |> Enum.map(& &1.count) |> Enum.sum()

  describe "the sweep and Forget" do
    setup c do
      lead = lead_fixture(c.fs, team: c.backend, profile: c.golang)
      mei = contact_fixture(c.fs, name: "Mei Chen")

      {:ok, _} =
        Data.Contacts.link_lead(%{lead_id: lead.id, contact_id: mei.id, role: :recruiter})

      corvid = company_fixture(c.org, name: "Corvid Security")
      {:ok, mei} = Data.Contacts.update(mei, %{company_id: corvid.id})
      _job = job_fixture(c.fs, team: c.backend, company: corvid)
      %{mei: mei, corvid: corvid}
    end

    defp seen(c, subject, at) do
      {:ok, o} =
        Behaviour.observe(
          c.fs,
          Map.merge(subject, %{
            kind: :seen_online,
            source: :manual,
            observed_at: at,
            active_at: at
          })
        )

      o
    end

    test "observations older than 180 days go, the hour counts stay; a second run deletes nothing",
         c do
      old = DateTime.add(@now, -181 * 86_400, :second)
      _old = seen(c, %{contact_id: c.mei.id}, old)
      _new = seen(c, %{contact_id: c.mei.id}, @now)

      assert Privacy.sweep(@now) == %{deleted: 1}
      assert Privacy.sweep(@now) == %{deleted: 0}
      assert [%{observed_at: @now}] = observations()
      assert count(:contact_id, c.mei.id) == 2

      {:ok, _} = Data.Organisations.put_settings(c.org.id, %{observation_retention_days: 30})
      assert Privacy.sweep(DateTime.add(@now, 31 * 86_400, :second)) == %{deleted: 1}
    end

    test "a team lead forgets a person: observations, counts and watches go, do-not-contact; staff can't",
         c do
      _ = seen(c, %{contact_id: c.mei.id}, @now)
      _ = seen(c, %{company_id: c.corvid.id}, @now)

      {:ok, {:created, _watch}} =
        Core.Watches.create(c.fs, %{"contact_id" => c.mei.id, "trigger" => "replies"}, @now)

      assert {:error, :forget_not_allowed} = Privacy.forget_contact(c.fs, c.mei.id, @now)

      assert {:error, :not_found} =
               Privacy.forget_contact(customer_scope_for(c.tanweer), c.mei.id, @now)

      assert {:ok, %{is_do_not_contact: true, id: id}} =
               Privacy.forget_contact(scope_for(c.hira), c.mei.id, @now)

      assert id == c.mei.id
      assert [%{company_id: company_id}] = observations()
      assert company_id == c.corvid.id
      assert hours(:contact_id, c.mei.id) == []
      assert Repo.all(Data.Behaviour.Watch) == []

      assert [%{action: "forgotten", subject_id: ^id}] =
               Repo.all(from(e in Data.Audit.AuditEvent, where: e.action == "forgotten"))
    end

    test "forget its people: each contact of the company; the company's own history stays", c do
      _ = seen(c, %{contact_id: c.mei.id}, @now)
      _ = seen(c, %{company_id: c.corvid.id}, @now)

      assert {:error, :forget_not_allowed} = Privacy.forget_people(c.fs, c.corvid.id, @now)
      assert {:ok, %{forgotten: 1}} = Privacy.forget_people(scope_for(c.dawud), c.corvid.id, @now)
      assert [%{company_id: company_id}] = observations()
      assert company_id == c.corvid.id
      assert Data.Contacts.get(c.org.id, c.mei.id).is_do_not_contact
    end
  end
end
