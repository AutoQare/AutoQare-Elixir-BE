defmodule Notifire.Workers.EmailChangeWorker do
  @moduledoc """
  Sends the link that proves a new address (AQ-01 §6.1 `POST /me/email`),
  to the **new** address. The token rides in the job's args, as a reset's
  does. P10b (AQ-10B §5.1): the same worker tells the **old** address —
  `email_change_notice` when a change is asked (the token row's account),
  `email_changed` when it is done (`options`: `old_email`, `new_email`).
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias Data.Accounts
  alias Data.Accounts.UserToken
  alias Data.Mail.Command
  alias Notifire.Email
  alias Notifire.Mailer

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Command.from_job_args(args) do
      {:ok, %Command{kind: :email_change, subject_id: id, secret: token}} when is_binary(token) ->
        deliver(Accounts.get_token_for_system(id), token)

      {:ok, %Command{kind: :email_change_notice, subject_id: id}} ->
        notice(Accounts.get_token_for_system(id))

      {:ok, %Command{kind: :email_changed, subject_id: id, options: options}} ->
        changed(Accounts.get_user(id), options)

      _unusable ->
        Logger.error("email change job has unusable args: #{inspect(Map.keys(args))}")
        {:cancel, :invalid_args}
    end
  end

  defp deliver(%UserToken{purpose: :change_email} = row, token) do
    case row |> Email.email_change(token) |> Mailer.deliver() do
      {:ok, _metadata} ->
        {:ok, _sent} = Accounts.mark_token_sent(row, DateTime.utc_now())
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(_consumed_or_gone, _token) do
    Logger.info("email change consumed before delivery; nothing to send")
    :ok
  end

  defp notice(%UserToken{purpose: :change_email} = row) do
    row |> Email.email_change_notice(nil) |> send_it()
  end

  defp notice(_gone), do: :ok

  defp changed(%{} = user, %{"old_email" => old, "new_email" => new})
       when is_binary(old) and is_binary(new) do
    user |> Email.email_changed(old, new) |> send_it()
  end

  defp changed(_gone, _options), do: :ok

  defp send_it(email) do
    case Mailer.deliver(email) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
