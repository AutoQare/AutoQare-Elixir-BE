defmodule Core.Notifications.CustomerMail do
  @moduledoc """
  Mail for a customer with no portal login (AQ-10B §11.4, QP10b-2): they
  have no bell, so they get **email only, and only** for a meeting
  scheduled, changed or tomorrow (with its `.ics`), a milestone (an
  interview, an offer, *Hired*) and the weekly report. Each email says
  "Ask your team for a portal invitation to see everything."

  `write/3` keeps the words as a `customer_mail` row, once per dedupe key,
  in the caller's transaction, and asks for the delivery sweep by its name
  in config, which renders and sends it (`core` and `notifire` never call
  each other). A customer with a login, or with no address, gets none.
  """

  alias Core.Notifications.Deliveries
  alias Data.Notifications.CustomerMails

  @kinds ~w(meetings.scheduled meetings.changed meetings.day_before leads.customer_milestone
            leads.weekly_report)

  @doc "The kinds a customer with no login is mailed."
  def kinds, do: @kinds

  @doc """
  Writes the mail for `customer` (a customer row) when they have no login
  and an address: `attrs` holds `kind`, `subject`, `text`, `dedupe` and
  optionally `ics`. Answers `:written`, `:there` or `:none`.
  """
  @spec write(map(), map(), DateTime.t()) :: :written | :there | :none
  def write(%{user_id: nil, email: email} = customer, %{kind: kind} = attrs, %DateTime{} = now)
      when kind in @kinds and is_binary(email) and email != "" do
    {state, _row} =
      CustomerMails.ensure(
        %{
          organisation_id: customer.organisation_id,
          customer_id: customer.id,
          kind_key: kind,
          dedupe_key: attrs.dedupe,
          to_email: email,
          subject: attrs.subject,
          text: attrs.text,
          ics: attrs[:ics]
        },
        now
      )

    case state do
      :new ->
        :ok = Deliveries.deliver_soon()
        :written

      :there ->
        :there
    end
  end

  def write(_customer, _attrs, _now), do: :none
end
