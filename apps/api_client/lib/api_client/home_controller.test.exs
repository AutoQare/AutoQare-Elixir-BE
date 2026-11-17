defmodule ApiClient.HomeControllerTest do
  @moduledoc """
  AQ-11 §7.4 over HTTP: `GET /client/v1/home`, the customer's own, its
  exact keys; `replies` null when no team lets them see conversations; a
  staff account is refused before any controller runs.
  """

  use ApiClient.ClientCase, async: true

  alias Core.Clock
  alias Core.Leads.Ledger

  @now ~U[2026-11-12 07:00:00.000000Z]

  setup do
    on_exit(&Clock.unfreeze/0)
    Clock.freeze(@now)
    c = board_cast_fixture()
    fs = scope_for(c.fiza)
    job = job_fixture(fs, team: c.backend, title: "Backend Developer")

    {:ok, lead} =
      Core.Leads.create(fs, %{job_id: job.id, profile_id: c.golang.id, as: "apply"}, @now)

    lead = Data.Leads.get(c.org.id, lead.id)
    meeting_fixture(fs, lead: lead, starts_at: ~U[2026-11-13 05:00:00.000000Z])

    approval_fixture(fs,
      lead: lead,
      state: :pending,
      slots: [:customer],
      due_at: ~U[2026-11-14 05:00:00.000000Z]
    )

    task_fixture(fs,
      team: c.backend,
      customer: c.tanweer,
      customer_access: :assigned,
      due_on: ~D[2026-11-13]
    )

    contact = contact_fixture(fs, name: "Mei Chen")
    m = message_fixture(fs, lead: lead, contact: contact, sent_at: @now)
    Ledger.record(fs, lead, :message_in, %{message_id: m.id, occurred_at: @now}, @now)
    Map.put(c, :lead, lead)
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "GET /home: the shape, exactly", c do
    conn = as_customer(c.tanweer, :get, "/v1/home")
    assert conn.status == 200
    home = body(conn)

    assert keys(home) == ~w(next profiles replies)
    assert [profile] = home["profiles"]
    assert keys(profile) == ~w(last_week profile stages this_week)
    assert keys(profile["profile"]) == ~w(id title)
    assert profile["this_week"] == 1
    assert [stage] = profile["stages"]
    assert stage == %{"key" => "applied", "label" => "Applied", "count" => 1}

    assert keys(home["next"]) == ~w(approvals meetings tasks)
    assert [meeting] = home["next"]["meetings"]
    assert keys(meeting) == ~w(ends_at id starts_at time_zone title)
    assert [approval] = home["next"]["approvals"]
    assert keys(approval) == ~w(due_at id title)
    assert [task] = home["next"]["tasks"]
    assert keys(task) == ~w(due_on id title)
    assert task["due_on"] == "2026-11-13"

    assert [reply] = home["replies"]
    assert keys(reply) == ~w(at excerpt from_name lead_id title)
    assert reply["from_name"] == "Mei Chen"
    assert reply["lead_id"] == c.lead.id

    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{customer_sees_conversations: false})
    assert body(as_customer(c.tanweer, :get, "/v1/home"))["replies"] == nil
  end

  test "a staff account is not a customer", c do
    assert code(call(c.fiza, :get, "/v1/home")) == "not_a_customer"
  end
end
