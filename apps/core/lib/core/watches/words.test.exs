defmodule Core.Watches.WordsTest do
  @moduledoc "AQ-10 §8's words, kind by kind, and where each opens."

  use ExUnit.Case, async: true

  alias Core.Watches.Words

  doctest Words

  @corvid %{kind: :company, id: "co1", name: "Corvid Security", company: nil}
  @client %{
    kind: :contact,
    id: "ct1",
    name: "Dana Whitfield",
    company: %{id: "co1", name: "Corvid Security"}
  }
  @mei %{kind: :contact, id: "ct2", name: "Mei Chen", company: nil}

  defp ctx(kind, subject, attrs \\ %{}) do
    Map.merge(
      %{
        kind: kind,
        source: :extension,
        subject: subject,
        job: nil,
        observer: nil,
        ago: 0,
        lead: nil
      },
      attrs
    )
  end

  test "§8's four sentences" do
    assert Words.title(ctx(:seen_online, @client, %{observer: "Fiza"})) ==
             "Corvid Security's client is online on Upwork (Fiza has the room open)."

    assert Words.title(
             ctx(:job_posted, @corvid, %{source: :job, job: %{title: "Senior Go Engineer"}})
           ) ==
             "Corvid Security posted a job: Senior Go Engineer."

    lead = %{id: "l1", title: "Platform Engineer", company: "Juniper Edge"}

    assert Words.title(ctx(:replied, @mei, %{source: :email, lead: lead})) ==
             "Mei Chen replied on Platform Engineer at Juniper Edge."

    assert Words.title(ctx(:last_active_reported, @corvid, %{ago: 600})) ==
             "Corvid Security: new activity, last viewed their job 10 min ago."
  end

  test "the rest of the kinds" do
    assert Words.title(ctx(:seen_online, @mei)) ==
             "Mei Chen is online on Upwork (someone on the team has the room open)."

    assert Words.title(ctx(:seen_online, @mei, %{source: :manual})) == "Mei Chen was seen online."
    assert Words.title(ctx(:job_reposted, @corvid)) == "Corvid Security reposted a job."
    assert Words.title(ctx(:replied, @mei)) == "Mei Chen replied."

    assert Words.title(ctx(:last_active_reported, @mei, %{ago: 7200})) ==
             "Mei Chen: new activity, active 2 h ago."

    assert Words.title(ctx(:viewed_proposal, @corvid)) ==
             "Corvid Security: new activity, viewed a proposal."

    assert Words.title(ctx(:viewed_profile, @mei)) == "Mei Chen: new activity, viewed a profile."
    assert Words.title(ctx(:message_read, @mei)) == "Mei Chen: new activity, read a message."
  end

  test "it opens the subject's Behaviour tab, or a reply's lead" do
    assert Words.link(ctx(:job_posted, @corvid)) == "/companies/co1?tab=behaviour"
    assert Words.link(ctx(:seen_online, @client)) == "/contacts/ct1?tab=behaviour"

    assert Words.link(ctx(:replied, @mei, %{lead: %{id: "l1", title: "X", company: nil}})) ==
             "/leads/l1"

    assert Words.link(ctx(:replied, @mei)) == "/contacts/ct2?tab=behaviour"
  end
end
