defmodule Notifire do
  @moduledoc """
  Delivery: email (Swoosh), Web Push, and pushes to the extension (PLAN
  §11, §15.1).

  **A sibling of `core`, and neither calls the other.** `core` decides what to
  say and writes a row (or, for a message a row cannot reconstruct, enqueues
  a job naming a worker here through `config :core, :mail_workers`); this app
  delivers. A worker here is named to `core` in config, never in code.

  ## In P1

  Three workers, one per message: `Notifire.Workers.InvitationWorker`,
  `Notifire.Workers.PasswordResetWorker` and
  `Notifire.Workers.EmailChangeWorker`, with `Notifire.Email` saying what
  each looks like.

  ## In P8 (AQ-08 §7)

  The deliveries ledger is the seam: `core` plans a notification's rows in
  its transaction, and `Notifire.Delivery.run/2` (run by
  `Notifire.Workers.DeliveryWorker` on write and every five minutes) sends
  the due push and email rows. `Notifire.Push` is Web Push (tCart's, with
  the dev outbox `Notifire.Push.Outbox`); `Notifire.Email.for_notification/2`
  is a notification as mail. The extension's rows are claimed by its poll,
  in `core`.

  ## In P10b (AQ-10B §7, §11.4)

  Every email is designed and compiled: `priv/emails/` holds the layout,
  the parts and each kind's `subject.txt`, `body.html`, `body.text` and
  `push.md` per audience (`Notifire.Emails.Templates`, `EEx.function_from_file`;
  a kind that emails with no template fails the build), joined by
  `Notifire.Emails.Renderer` with `Notifire.Emails.Html` (escaping, the
  button, the facts, the preheader) and `Notifire.Emails.Why` (the
  footer's first line). `Notifire.Email` adds the headers (`From`,
  `Reply-To`, `List-Unsubscribe`, `X-AQ-Kind`). The sweep also sends
  `customer_mail` for customers with no portal login, and
  `Notifire.Emails.Gallery` is `/dev/emails`.
  """
end
