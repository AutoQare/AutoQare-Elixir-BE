defmodule Notifire.Delivery do
  @moduledoc """
  Sending what the ledger says is due (AQ-08 §7.2, §11.4; tCart's
  `Notifire.Delivery.run/1`, over `notification_deliveries`).

  **The far side of the seam.** `core` and `notifire` are siblings, so
  `core` plans a notification's rows in its transaction and this reads
  them: the queue is the database. A mailer being down leaves rows waiting
  rather than failing the write that produced them.

  `run/2` takes the due `pending` push and email rows, oldest
  `deliver_after` first, at most 200, **each under `FOR UPDATE SKIP
  LOCKED` in its own transaction**, so two runs never take the same row.
  For each:
  - **the person has since turned the channel off** for the group or the
    kind (P10b: off at either level; a locked kind can't be) →
    `skipped · preference_off`;
  - **a staff email whose notification was read** → `skipped · read`,
    except the `meetings`, `account` and `system` groups' and a locked
    kind's; **a customer's email is never skipped as read** (AQ-10B
    QP10b-11);
  - **push**: to every browser the person turned on in their app; sent if
    any took it; a 404 or 410 deletes that browser; none left (or no VAPID
    keys) → `skipped · no_target`; browsers left but every one refusing →
    a failure;
  - **email**: Swoosh, with a meeting's invite attached.

  **A failure is recorded, never swallowed**: `attempts` + 1 and the error
  kept (never a body); under three the row stays `pending`, due five
  minutes on; the third makes it `failed`. Each run also skips the
  extension's rows nobody claimed within a day (`no_target`).

  `deliver_after` is what quiet hours set, so a held row is simply not due
  yet: deferred, never dropped. Workers hold no rules: every rule is
  asserted here.

  **P10b:** push words come from the kind's `push.md` (AQ-10B §7.2), and
  each run also sends the `customer_mail` rows waiting for customers with
  no portal login (QP10b-2), each in its own transaction under the same
  lock, three attempts.
  """

  alias Data.Notifications
  alias Data.Notifications.{CustomerMails, Deliveries, Delivery, KindPreference}
  alias Data.Notifications.{KindPreferences, Mail, Notification, Preferences}
  alias Data.Repo
  alias Notifire.Email
  alias Notifire.Emails.{Renderer, Templates}
  alias Notifire.Mailer
  alias Notifire.Push

  require Logger

  @most 200
  @attempts 3
  @retry_s 5 * 60
  @email_always ~w(meetings account system)

  @doc """
  Sends everything due at `now`. Answers `%{sent, skipped, failed}`
  (`failed` counts failed attempts, whether or not the row stays pending).
  `opts`: `mailer:` overrides the mailer's config, `push:` the push
  options (`send: true`).
  """
  @spec run(DateTime.t(), keyword()) :: %{
          sent: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }
  def run(%DateTime{} = now, opts \\ []) do
    tally = sweep(%{sent: 0, skipped: 0, failed: 0}, now, opts, @most)
    tally = customer_mail(tally, now, opts, @most)
    %{tally | skipped: tally.skipped + Deliveries.skip_unclaimed_for_system(now)}
  end

  # ── Customers with no portal login (AQ-10B §11.4, QP10b-2) ──────────────────

  defp customer_mail(tally, _now, _opts, 0), do: tally

  defp customer_mail(tally, now, opts, left) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        case CustomerMails.next_pending_for_system() do
          nil -> :done
          row -> send_customer_mail(row, now, opts)
        end
      end)

    case outcome do
      :done -> tally
      outcome -> customer_mail(Map.update!(tally, outcome, &(&1 + 1)), now, opts, left - 1)
    end
  end

  @doc "Sends one locked `customer_mail` row. Answers `:sent`, `:skipped` or `:failed`."
  @spec send_customer_mail(map(), DateTime.t(), keyword()) :: :sent | :skipped | :failed
  def send_customer_mail(row, now, opts) do
    case Mail.customer(row.customer_id) do
      %{user_id: nil} = customer ->
        {email, rendered} = Email.for_customer_mail(row, customer)

        case Mailer.deliver(email, Keyword.get(opts, :mailer, [])) do
          {:ok, _metadata} ->
            :ok = CustomerMails.mark_sent(row, rendered.html, rendered.text, now)
            :sent

          {:error, reason} ->
            Logger.warning("customer mail #{row.id} failed: #{describe(reason)}")
            _state = CustomerMails.record_failure(row, describe(reason), now, @attempts)
            :failed
        end

      _gone_or_has_a_login ->
        :ok = CustomerMails.mark_skipped(row, now)
        :skipped
    end
  end

  defp sweep(tally, _now, _opts, 0), do: tally

  defp sweep(tally, now, opts, left) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        case Deliveries.next_due_for_system(now) do
          nil -> :done
          row -> deliver(row, now, opts)
        end
      end)

    case outcome do
      :done -> tally
      outcome -> sweep(Map.update!(tally, outcome, &(&1 + 1)), now, opts, left - 1)
    end
  end

  @doc "Delivers one locked row. Answers `:sent`, `:skipped` or `:failed`."
  @spec deliver(Delivery.t(), DateTime.t(), keyword()) :: :sent | :skipped | :failed
  def deliver(%Delivery{notification: %Notification{} = n} = row, now, opts) do
    group = n.notification_kind.notification_group
    who = Notifications.recipient(row.user_id)

    cond do
      is_nil(who) -> skip(row, :no_target, now)
      switched_off?(row, n.notification_kind, group) -> skip(row, :preference_off, now)
      read_first?(row, n, group, who) -> skip(row, :read, now)
      row.channel == :push -> push(row, n, who, now, opts)
      row.channel == :email -> email(row, n, who, now, opts)
    end
  end

  defp switched_off?(_row, %{is_locked: true}, _group), do: false

  defp switched_off?(row, kind, group) do
    (group.can_disable and Preferences.switches(row.user_id, group.key)[row.channel] == false) or
      kind_off?(row, kind)
  end

  defp kind_off?(row, kind) do
    case KindPreferences.get(row.user_id, kind.key) do
      nil -> false
      prefs -> KindPreference.switches(prefs)[row.channel] == false
    end
  end

  defp read_first?(%{channel: :email}, %{read_at: %DateTime{}} = n, group, who),
    do:
      not who.customer? and group.key not in @email_always and
        not n.notification_kind.is_locked

  defp read_first?(_row, _n, _group, _who), do: false

  defp push(row, n, who, now, opts) do
    words = push_words(n, who)
    payload = %{title: words.title, body: words.body, tag: n.id, url: Notification.open_path(n)}

    if Push.configured?() do
      result = Push.deliver(row.user_id, who.app, payload, now, Keyword.get(opts, :push, []))

      cond do
        result.sent > 0 -> sent(row, now)
        result.failed > 0 -> fail(row, result.error, now)
        true -> skip(row, :no_target, now)
      end
    else
      skip(row, :no_target, now)
    end
  end

  defp email(row, n, who, now, opts) do
    n
    |> Email.for_notification(who, row.ics, now)
    |> Mailer.deliver(Keyword.get(opts, :mailer, []))
    |> case do
      {:ok, _metadata} -> sent(row, now)
      {:error, reason} -> fail(row, describe(reason), now)
    end
  end

  # A kind's push words from its `push.md`, else the row's own.
  defp push_words(n, who) do
    audience = if who.customer?, do: "customer", else: "staff"

    if Templates.has?(n.notification_kind_key, audience),
      do: Renderer.push(n.notification_kind_key, audience, %{title: n.title, body: n.body}),
      else: %{title: n.title, body: n.body}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp sent(row, now) do
    :ok = Deliveries.mark_sent(row, now)
    :sent
  end

  defp skip(row, reason, now) do
    :ok = Deliveries.mark_skipped(row, reason, now)
    :skipped
  end

  defp fail(row, error, now) do
    Logger.warning("delivery #{row.id} (#{row.channel}) failed: #{error}")
    retry_at = DateTime.add(now, @retry_s, :second)
    _state = Deliveries.record_failure(row, error, now, retry_at, @attempts)
    :failed
  end
end
