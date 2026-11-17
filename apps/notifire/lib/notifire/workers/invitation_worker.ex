defmodule Notifire.Workers.InvitationWorker do
  @moduledoc """
  Mails one invitation (AQ-01 §6.2: *the mail goes out through `notifire`*),
  or its reminder (`invitation_reminder`, AQ-10B §5.1 A2: three days on and
  the day before it expires; nothing once it has expired).
  Enqueued by `core` through `Core.Mail`, named here only in config. The
  code is in the row, so the job carries only the id; a row that was revoked
  or accepted before delivery is nothing to send.
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias Data.Invitations
  alias Data.Invitations.Invitation
  alias Data.Mail.Command
  alias Notifire.Email
  alias Notifire.Mailer

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Command.from_job_args(args) do
      {:ok, %Command{kind: kind, subject_id: id}} -> deliver(Invitations.get_for_system(id), kind)
      {:error, why} -> {:cancel, why}
    end
  end

  defp deliver(%Invitation{accepted_at: nil, revoked_at: nil} = invitation, kind) do
    now = Utils.Clock.now()

    email =
      if kind == :invitation_reminder,
        do: Email.invitation_reminder(invitation, now),
        else: Email.invitation(invitation)

    if kind == :invitation_reminder and DateTime.compare(invitation.expires_at, now) != :gt do
      :ok
    else
      case Mailer.deliver(email) do
        {:ok, _metadata} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp deliver(_gone_or_closed, _kind) do
    Logger.info("invitation closed before delivery; nothing to send")
    :ok
  end
end
