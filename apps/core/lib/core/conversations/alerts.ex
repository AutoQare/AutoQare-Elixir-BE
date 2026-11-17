defmodule Core.Conversations.Alerts do
  @moduledoc """
  Job-alert emails (AQ-12 §7, §11.4, QP12-23), **pure**: a parsed mail in,
  whether it is LinkedIn's or Indeed's alert and the jobs it lists out.
  `Core.Inbound` asks before landing anything: **an alert is read, never
  landed in triage**, and `Core.Jobs.Alerts` turns its jobs into pool jobs.

  **Recognised** by its sender and its subject together:

  - the sender is LinkedIn's or Indeed's (`Core.Conversations.Platforms`);
  - and either the sender says so (`jobalerts-noreply@linkedin.com`,
    `jobs-listings@linkedin.com`, `alert@indeed.com`,
    `…@jobalert.indeed.com`) or the subject does ("“golang developer”: 3
    new jobs", "15 new jobs for Golang developer", "2 new golang developer
    jobs in Remote", "Jobs similar to …");
  - and it is no application notice (P9's subjects stay notices, QP9-10);
  - and its body holds at least one job link.

  **Its jobs** are the links in the body — the text's, then the HTML's —
  that `Utils.JobKey` reads as LinkedIn's (`/jobs/view/{id}`,
  `/comm/jobs/view/{id}`) or Indeed's (`jk` in `/viewjob`, `/rc/clk`,
  `/pagead/clk`), each key once, **at most 30** (QP12-24). For each, what
  the email says: the lines above the link in its paragraph are the title,
  then the company and the location — LinkedIn writes them on two lines,
  Indeed as "Company - Location" — with badges, pay and buttons left out;
  an HTML-only alert gives the link's own words as the title. The link
  kept is the job's own page, without the tracking.
  """

  alias Core.Conversations.Platforms
  alias Utils.JobKey

  @max 30

  @alert_sender ~r/alert|jobs-listings/i
  @alert_subject ~r/\bjob alerts?\b|\bnew jobs?\b|\b\d+\+?\s+(?:new\s+)?(?:[\w'’ .-]+\s+)?(?:jobs|opportunities)\b|\bjobs?\s+(?:for|in|near|similar to|matching|you may)\b|\bopportunit(?:y|ies)\b/iu

  # Lines of a job's paragraph that are neither its title, company nor
  # place: a badge on its own, a button, a count, the pay.
  @badge ~r/^(?:easily apply|actively recruiting|be an early applicant|promoted|urgently hiring|responsive employer|hiring multiple candidates|new|just posted)$/iu
  @noise ~r/^(?:view job|apply|see (?:all|more)|unsubscribe|\d+\s+(?:connections?|alumni|applicants?|school alum)|your profile matches)|\b(?:a|an|per)\s+(?:year|hour|month|week|day)\b|[$£€₹]\s?\d|\b(?:PKR|USD|GBP|EUR|INR)\s?\d/iu

  @type job :: %{
          key: String.t(),
          source: :linkedin | :indeed,
          source_job_id: String.t(),
          url: String.t(),
          title: String.t() | nil,
          company: String.t() | nil,
          location: String.t() | nil
        }

  @doc "At most this many jobs from one alert (QP12-24)."
  @spec max_jobs() :: pos_integer()
  def max_jobs, do: @max

  @doc """
  The alert a mail is: `{:ok, %{platform, jobs}}`, or `:no` for any other
  mail.

      iex> Core.Conversations.Alerts.read(%{from: {"Omar", "omar@corvid.example"}, subject: "3 new jobs", text: "", html: nil})
      :no
  """
  @spec read(map()) :: {:ok, %{platform: :linkedin | :indeed, jobs: [job()]}} | :no
  def read(%{from: {_name, address}} = mail) do
    platform = Platforms.platform(address)
    subject = mail[:subject]

    with true <- platform in [:linkedin, :indeed],
         nil <- Platforms.notice(subject),
         true <- alert_sender?(address) or alert_subject?(subject),
         [_ | _] = jobs <- jobs(mail) do
      {:ok, %{platform: platform, jobs: jobs}}
    else
      _other -> :no
    end
  end

  def read(_mail), do: :no

  @doc ~S"""
  Whether a subject reads as an alert's.

      iex> Core.Conversations.Alerts.alert_subject?("“golang developer”: 3 new jobs")
      true
      iex> Core.Conversations.Alerts.alert_subject?("2 new golang developer jobs in Remote")
      true
      iex> Core.Conversations.Alerts.alert_subject?("Your application was sent to Corvid Security")
      false
  """
  @spec alert_subject?(String.t() | nil) :: boolean()
  def alert_subject?(subject) when is_binary(subject), do: subject =~ @alert_subject
  def alert_subject?(_subject), do: false

  defp alert_sender?(address) do
    [local | domain] = address |> String.downcase() |> String.split("@")
    local =~ @alert_sender or Enum.any?(domain, &(&1 =~ ~r/alert/))
  end

  @doc """
  The jobs a mail's body lists, in order, each key once, at most 30.
  """
  @spec jobs(map()) :: [job()]
  def jobs(mail) do
    text = mail[:text] || ""
    html = mail[:html] || ""
    details = details(text)

    (Enum.map(urls(text), &{&1, nil}) ++ anchors(html))
    |> Enum.flat_map(fn {url, words} -> job(url, words, details) end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.take(@max)
  end

  defp job(url, words, details) do
    case JobKey.parse(unwrap(url)) do
      {:ok, %{source: source} = parsed} when source in [:linkedin, :indeed] ->
        said = Map.get(details, parsed.key, %{title: clean(words), company: nil, location: nil})

        [
          Map.merge(parsed, %{
            url: page(source, parsed.source_job_id),
            title: said.title || clean(words),
            company: said.company,
            location: said.location
          })
        ]

      _not_a_job ->
        []
    end
  end

  # LinkedIn's mail links go through `/comm/`; the job is the same.
  defp unwrap(url) do
    url
    |> String.replace("&amp;", "&")
    |> String.replace(~r{(linkedin\.com)/comm/}i, "\\1/")
  end

  defp page(:linkedin, id), do: "https://www.linkedin.com/jobs/view/#{id}"
  defp page(:indeed, jk), do: "https://www.indeed.com/viewjob?jk=#{jk}"

  defp urls(text), do: ~r{https?://[^\s<>"')\]]+}i |> Regex.scan(text) |> List.flatten()

  defp anchors(html) do
    ~r{<a\b[^>]*\bhref\s*=\s*"([^"]+)"[^>]*>(.*?)</a>}is
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [url, inner] -> {url, String.replace(inner, ~r/<[^>]*>/, " ")} end)
  end

  # Per job key, what its first paragraph says above its link (a job a
  # mail repeats keeps what it said first).
  defp details(text) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.flat_map(&paragraph/1)
    |> Enum.reduce(%{}, fn {key, said}, acc -> Map.put_new(acc, key, said) end)
  end

  defp paragraph(paragraph) do
    lines = paragraph |> String.split("\n") |> Enum.map(&String.trim/1)

    case Enum.find_index(lines, &(urls(&1) != [])) do
      nil ->
        []

      at ->
        with [url | _rest] <- urls(Enum.at(lines, at)),
             {:ok, %{key: key}} <- JobKey.parse(unwrap(url)) do
          words = lines |> Enum.take(at) |> Enum.reject(&noise?/1)
          [{key, said(words)}]
        else
          _other -> []
        end
    end
  end

  defp noise?(line), do: line == "" or line =~ @badge or line =~ @noise

  defp said([]), do: %{title: nil, company: nil, location: nil}
  defp said([title]), do: %{title: clean(title), company: nil, location: nil}

  defp said([title, second | rest]) do
    case {String.split(second, ~r/\s+[-–—·•]\s+/u, parts: 2), rest} do
      {[company, location], _rest} ->
        %{title: clean(title), company: clean(company), location: clean(location)}

      {[company], [location | _more]} ->
        %{title: clean(title), company: clean(company), location: clean(location)}

      {[company], []} ->
        %{title: clean(title), company: clean(company), location: nil}
    end
  end

  defp clean(nil), do: nil

  defp clean(text) do
    case text |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> nil
      words -> String.slice(words, 0, 300)
    end
  end
end
