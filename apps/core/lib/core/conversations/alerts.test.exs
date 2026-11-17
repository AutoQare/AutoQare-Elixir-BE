defmodule Core.Conversations.AlertsTest do
  @moduledoc """
  AQ-12 §7, §11.4: LinkedIn's and Indeed's job alerts recognised by sender
  and subject, their jobs read from the body — each key once, at most 30,
  with what the email says and the job's own link — on the made-up alerts
  in `priv/eml/`; a notice, a person's mail, a platform mail with no job
  and Fiverr's notice are no alert.
  """

  use ExUnit.Case, async: true

  alias Core.Conversations.{Alerts, Eml}

  doctest Alerts

  defp mail(name) do
    {:ok, mail} = Eml.parse(File.read!(Path.expand("../../../priv/eml/" <> name, __DIR__)))
    mail
  end

  defp raw(from, subject, body, type \\ "text/plain") do
    {:ok, mail} =
      Eml.parse("""
      Message-ID: <#{System.unique_integer([:positive])}@mail.example>
      Date: Tue, 10 Nov 2026 06:15:00 +0000
      From: #{from}
      To: Tanweer <tanweer@example.com>
      Subject: #{subject}
      MIME-Version: 1.0
      Content-Type: #{type}; charset=utf-8

      #{body}
      """)

    mail
  end

  test "LinkedIn's alert: three jobs, each with its title, company and place, the link without tracking" do
    assert {:ok, %{platform: :linkedin, jobs: jobs}} = Alerts.read(mail("linkedin-alert.eml"))

    assert Enum.map(jobs, & &1.key) ==
             ~w(linkedin:4012233871 linkedin:4012233999 linkedin:4012234111)

    [corvid, juniper, northwind] = jobs

    assert corvid == %{
             key: "linkedin:4012233871",
             source: :linkedin,
             source_job_id: "4012233871",
             url: "https://www.linkedin.com/jobs/view/4012233871",
             title: "Senior Golang Engineer",
             company: "Corvid Security",
             location: "Remote"
           }

    assert %{title: "Backend Developer (Go)", company: "Juniper Edge"} = juniper
    assert juniper.location == "Karachi, Sindh, Pakistan (Hybrid)"
    assert %{title: "Platform Engineer", location: "European Union (Remote)"} = northwind
  end

  test "Indeed's alert: a job repeated is read once, with what it said first; Company - Place on one line" do
    assert {:ok, %{platform: :indeed, jobs: [acme, bluefin]}} =
             Alerts.read(mail("indeed-alert.eml"))

    assert acme == %{
             key: "indeed:5f2b1c9d8e7a6b5c",
             source: :indeed,
             source_job_id: "5f2b1c9d8e7a6b5c",
             url: "https://www.indeed.com/viewjob?jk=5f2b1c9d8e7a6b5c",
             title: "Senior Go Developer",
             company: "Acme Payments",
             location: "Remote"
           }

    assert %{key: "indeed:0a1b2c3d4e5f6a7b", title: "Golang Backend Engineer"} = bluefin
    assert %{company: "Bluefin Labs", location: "Remote in Lahore"} = bluefin
  end

  test "an alert in HTML alone: the link's own words are the title" do
    html =
      ~s(<p><a href="https://www.linkedin.com/comm/jobs/view/4099?trackingId=x&amp;refId=y">) <>
        ~s(<b>Elixir Engineer</b></a></p><p><a href="https://www.linkedin.com/feed">Feed</a></p>)

    mail =
      raw(
        "LinkedIn <jobalerts-noreply@linkedin.com>",
        "Elixir engineer: 1 new job",
        html,
        "text/html"
      )

    assert {:ok, %{jobs: [%{key: "linkedin:4099", title: "Elixir Engineer", company: nil}]}} =
             Alerts.read(mail)
  end

  test "at most 30 jobs from one alert (QP12-24)" do
    body =
      Enum.map_join(1..40, "\n\n", fn n ->
        "Go role #{n}\nCompany #{n}\nRemote\nhttps://www.indeed.com/viewjob?jk=k#{n}"
      end)

    mail = raw("Indeed <alert@indeed.com>", "40 new go jobs in Remote", body)

    assert {:ok, %{jobs: jobs}} = Alerts.read(mail)
    assert length(jobs) == 30 and hd(jobs).key == "indeed:k1"
  end

  test "no alert: an application notice, a person, a platform mail without a job, Fiverr" do
    assert Alerts.read(mail("indeed-notice.eml")) == :no
    assert Alerts.read(mail("stranger-corvid.eml")) == :no
    assert Alerts.read(mail("fiverr-brief.eml")) == :no

    viewed =
      raw(
        "LinkedIn <notifications-noreply@linkedin.com>",
        "Tanweer, you appeared in 9 searches this week",
        "See who's looking: https://www.linkedin.com/me/search-appearances"
      )

    assert Alerts.read(viewed) == :no

    # A job link from LinkedIn that is no alert: someone sharing one.
    shared =
      raw(
        "Mei Chen via LinkedIn <messages-noreply@linkedin.com>",
        "Mei sent you a message",
        "Have a look: https://www.linkedin.com/jobs/view/4012233871"
      )

    assert Alerts.read(shared) == :no
  end
end
