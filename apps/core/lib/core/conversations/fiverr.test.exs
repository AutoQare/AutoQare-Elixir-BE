defmodule Core.Conversations.FiverrTest do
  @moduledoc """
  AQ-12 §6, §11.4 (QP12-22): Fiverr by email and by hand. A forwarded
  Fiverr notice lands as a conversation on `platform: fiverr`, in triage
  on the receiving profile; *Create job and lead* there takes
  `origin_kind` (required) and no link — the job keyed by its
  conversation, a brief's link kept, a brief applied as `brief_response`
  — and an email conversation refuses `origin_kind`.
  """

  use Core.CoreCase, async: true

  alias Core.Conversations.Triage
  alias Core.Inbound
  alias Data.Scope

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    channel = channel_fixture(c.tanweer, kind: :email, handle: "tanweer@example.com")
    :ok = Data.Profiles.put_channels(c.golang, [channel.id])
    Map.merge(c, %{fiza_scope: scope_for(c.fiza), channel: Data.Channels.reload(channel)})
  end

  defp eml(name), do: File.read!(Path.expand("../../../priv/eml/" <> name, __DIR__))

  defp deliver(c, raw) do
    {:ok, answer} =
      Inbound.dev(
        Scope.system(),
        %{"to" => Inbound.address(c.channel.inbound_token), "eml" => raw},
        @now
      )

    answer
  end

  # Another Fiverr notice: a buyer's message, no link to keep.
  defp inquiry do
    eml("fiverr-brief.eml")
    |> String.replace("brief-88213.20261110@e.fiverr.com", "inbox-4471.20261110@e.fiverr.com")
    |> String.replace(
      "You've been invited to a new Brief: Go microservice for payment webhooks",
      "New message from buyer jane_k"
    )
  end

  test "a Fiverr notice lands as a Fiverr conversation, in triage on the receiving profile", c do
    %{outcome: :landed, conversation_id: id} = deliver(c, eml("fiverr-brief.eml"))

    assert Repo.get!(Data.Conversations.Conversation, id).platform == :fiverr

    {:ok, %{items: [item]}} = Triage.list(c.fiza_scope, %{"team_id" => c.backend.id})
    assert item.conversation.id == id
    assert item.profile == %{id: c.golang.id, title: "Golang backend"}
  end

  test "Create job and lead on Fiverr: origin_kind required, the link optional, keyed by the conversation",
       c do
    %{conversation_id: id} = deliver(c, eml("fiverr-brief.eml"))
    job = %{"title" => "Go microservice for payment webhooks"}
    body = %{"profile_id" => c.golang.id, "job" => job}

    assert {:error, {:missing, [:origin_kind]}} = Triage.create_lead(c.fiza_scope, id, body, @now)

    assert {:error, {:invalid, %{"origin_kind" => _}}} =
             Triage.create_lead(c.fiza_scope, id, Map.put(body, "origin_kind", "gig"), @now)

    brief =
      body
      |> Map.put("origin_kind", "brief")
      |> put_in(["job", "url"], "https://www.fiverr.com/briefs/88213")

    assert {:ok, %{lead: card}} = Triage.create_lead(c.fiza_scope, id, brief, @now)

    lead = Data.Leads.get(c.org.id, card.id)

    assert %{
             source: :fiverr,
             canonical_key: "fiverr:conversation:" <> ^id,
             source_url: "https://www.fiverr.com/briefs/88213",
             origin_kind: :brief,
             title: "Go microservice for payment webhooks"
           } = lead.job

    assert lead.applied_via == :brief_response and lead.stage.kind == :inbound

    # A buyer's message: an inquiry, no link at all.
    %{conversation_id: other} = deliver(c, inquiry())

    asked =
      Map.merge(body, %{"origin_kind" => "inquiry", "job" => %{"title" => "Logo animation"}})

    assert {:ok, %{lead: card}} = Triage.create_lead(c.fiza_scope, other, asked, @now)

    lead = Data.Leads.get(c.org.id, card.id)
    assert lead.job.source_url == nil and lead.job.origin_kind == :inquiry
    assert lead.job.canonical_key == "fiverr:conversation:" <> other
    assert lead.applied_via == :recruiter_inbound
  end

  test "an email conversation takes no origin_kind and still needs the link", c do
    %{conversation_id: id} = deliver(c, eml("stranger-corvid.eml"))
    body = %{"profile_id" => c.golang.id, "job" => %{"title" => "Senior Golang Engineer"}}

    assert {:error, {:invalid, %{"job.url" => _}}} =
             Triage.create_lead(c.fiza_scope, id, body, @now)

    assert {:error, {:invalid, %{"origin_kind" => _}}} =
             Triage.create_lead(c.fiza_scope, id, Map.put(body, "origin_kind", "brief"), @now)
  end
end
