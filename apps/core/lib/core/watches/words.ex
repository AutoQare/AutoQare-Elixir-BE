defmodule Core.Watches.Words do
  @moduledoc """
  What a fired watch says and where it opens (AQ-10 §8, §11.4), **pure**:
  one sentence per observation kind, in the watcher's words.

  - "Corvid Security's client is online on Upwork (Fiza has the room
    open)." — a contact of a company; one with none is named;
  - "Bamboo Invest posted a job: Senior Go Engineer." (`reposted` for a
    repost);
  - "Mei Chen replied on Platform Engineer at Juniper Edge." (on the
    conversation's lead; "Mei Chen replied." on none);
  - "Corvid Security: new activity, last viewed their job 10 min ago." (a
    contact's: "active 2 h ago").

  It opens the subject's page (`/companies/:id?tab=behaviour`,
  `/contacts/:id?tab=behaviour`), or for a reply the conversation's lead.

  The context `ctx`: `kind`, `source`, `subject` (`%{kind, id, name,
  company}`, `company` the contact's `%{name}` or `nil`), `job` (`%{title}`
  or `nil`), `observer` (a first name or `nil`), `ago` (seconds between
  active and seen), `lead` (a reply's `%{id, title, company}` or `nil`).
  """

  @doc """
  The notification's title.

      iex> Core.Watches.Words.title(%{kind: :job_posted, source: :job,
      ...>   subject: %{kind: :company, id: "c", name: "Bamboo Invest", company: nil},
      ...>   job: %{title: "Senior Go Engineer"}, observer: nil, ago: 0, lead: nil})
      "Bamboo Invest posted a job: Senior Go Engineer."
  """
  @spec title(map()) :: String.t()
  def title(%{kind: :seen_online, source: :extension} = ctx),
    do: "#{who(ctx.subject)} is online on Upwork (#{room(ctx.observer)})."

  def title(%{kind: :seen_online} = ctx), do: "#{who(ctx.subject)} was seen online."
  def title(%{kind: :job_posted} = ctx), do: posted(ctx, "posted")
  def title(%{kind: :job_reposted} = ctx), do: posted(ctx, "reposted")

  def title(%{kind: :replied, lead: %{title: title, company: company}} = ctx)
      when is_binary(company),
      do: "#{ctx.subject.name} replied on #{title} at #{company}."

  def title(%{kind: :replied, lead: %{title: title}} = ctx),
    do: "#{ctx.subject.name} replied on #{title}."

  def title(%{kind: :replied} = ctx), do: "#{ctx.subject.name} replied."

  def title(%{kind: :last_active_reported, subject: %{kind: :company}} = ctx),
    do: "#{ctx.subject.name}: new activity, last viewed their job #{ago(ctx.ago)}."

  def title(%{kind: :last_active_reported} = ctx),
    do: "#{ctx.subject.name}: new activity, active #{ago(ctx.ago)}."

  def title(%{kind: :viewed_proposal} = ctx),
    do: "#{ctx.subject.name}: new activity, viewed a proposal."

  def title(%{kind: :viewed_profile} = ctx),
    do: "#{ctx.subject.name}: new activity, viewed a profile."

  def title(%{kind: :message_read} = ctx),
    do: "#{ctx.subject.name}: new activity, read a message."

  @doc "Where it opens: the reply's lead, else the subject's Behaviour tab."
  @spec link(map()) :: String.t()
  def link(%{kind: :replied, lead: %{id: id}}), do: "/leads/#{id}"
  def link(%{subject: %{kind: :company, id: id}}), do: "/companies/#{id}?tab=behaviour"
  def link(%{subject: %{kind: :contact, id: id}}), do: "/contacts/#{id}?tab=behaviour"

  defp who(%{kind: :contact, company: %{name: company}}) when is_binary(company),
    do: "#{company}'s client"

  defp who(subject), do: subject.name

  defp room(nil), do: "someone on the team has the room open"
  defp room(name), do: "#{name} has the room open"

  defp posted(%{job: %{title: title}} = ctx, verb) when is_binary(title),
    do: "#{ctx.subject.name} #{verb} a job: #{title}."

  defp posted(ctx, verb), do: "#{ctx.subject.name} #{verb} a job."

  @doc """
  How long ago, in the console's short words.

      iex> Core.Watches.Words.ago(600)
      "10 min ago"
      iex> Core.Watches.Words.ago(7200)
      "2 h ago"
  """
  @spec ago(integer()) :: String.t()
  def ago(s) when s < 60, do: "just now"
  def ago(s) when s < 3600, do: "#{div(s, 60)} min ago"
  def ago(s) when s < 86_400, do: "#{div(s, 3600)} h ago"
  def ago(s) when s < 2 * 86_400, do: "a day ago"
  def ago(s), do: "#{div(s, 86_400)} days ago"
end
