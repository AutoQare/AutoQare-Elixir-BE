defmodule Notifire.Emails.Why do
  @moduledoc """
  The footer's first line (AQ-10B §7.1, QP10b-9): why you got this email,
  per kind and audience — a kind's own words, else its group's.
  """

  @doc """
  Why you got this, per kind and audience (AQ-10B §7.1): a kind's own
  line, else its group's. `frequency` is the digest's.
  """
  @spec line(String.t(), boolean(), atom() | nil) :: String.t()
  def line(kind, customer?, frequency \\ :daily) do
    group = kind |> String.split(".") |> hd()
    why(kind, group, customer?, %{settings: %{digest_frequency: frequency}})
  end

  defp why("account.digest", _group, _customer?, recipient) do
    case recipient.settings.digest_frequency do
      :weekly -> "you get a weekly digest of what you haven't read."
      _daily -> "you get a daily digest of what you haven't read."
    end
  end

  defp why("account.weekly_summary", _g, _c, _r), do: "you get a summary of the week on Monday."
  defp why("leads.weekly_report", _g, _c, _r), do: "you get a report of your search on Monday."
  defp why("behaviour.watch_fired", _g, _c, _r), do: "you set up this watch."
  defp why("tasks.mentioned", _g, _c, _r), do: "someone mentioned you."
  defp why(_kind, group, true, _r), do: customer_why(group)
  defp why(_kind, group, false, _r), do: staff_why(group)

  defp staff_why("tasks"), do: "you're on this task."
  defp staff_why("leads"), do: "you own or watch this lead."
  defp staff_why("conversations"), do: "you own this lead or look after this customer."
  defp staff_why("meetings"), do: "you're on this meeting."
  defp staff_why("approvals"), do: "you're asked to decide, or you asked."
  defp staff_why("profiles"), do: "you look after this customer."
  defp staff_why("system"), do: "you're the system admin."
  defp staff_why(_account), do: "this is about your account."

  defp customer_why("tasks"), do: "your team shares this task with you."
  defp customer_why("leads"), do: "your team is applying for jobs for you."
  defp customer_why("conversations"), do: "your team shares this with you."
  defp customer_why("meetings"), do: "this meeting is about your application."
  defp customer_why("approvals"), do: "your team asked for your decision."
  defp customer_why("profiles"), do: "this is your profile."
  defp customer_why(_account), do: "this is about your account."
end
