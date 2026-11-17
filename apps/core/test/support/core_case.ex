defmodule Core.CoreCase do
  @moduledoc """
  For orchestration tests, which do touch the database.

  The pure engines need none of this — a rule that takes `now` and data and
  returns a decision runs without a sandbox, which is the point of keeping it
  pure.
  """

  use ExUnit.CaseTemplate

  alias Core.Leads.{Act, Ledger}
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Core.CoreCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  An `.eml` uploaded and confirmed by `scope`'s person (AQ-06 §11.6), from
  `apps/core/priv/eml/<name>` or the bytes given: the `eml` media row.
  """
  def eml_media(scope, name_or_bytes) do
    bytes =
      if String.ends_with?(name_or_bytes, ".eml"),
        do: File.read!(Path.expand("../../priv/eml/" <> name_or_bytes, __DIR__)),
        else: name_or_bytes

    {:ok, media, _target} =
      Core.Media.create(
        scope,
        %{
          "media_kind" => "eml",
          "content_type" => "message/rfc822",
          "byte_count" => byte_size(bytes),
          "original_filename" => "upload.eml"
        },
        "/media"
      )

    :ok = Core.Media.store(scope, media.id, bytes)
    {:ok, media} = Core.Media.confirm(scope, media.id, %{}, DateTime.utc_now())
    media
  end

  # ── Leads moved through their verbs at a given moment (AQ-11's tests) ───────

  @doc """
  An application through `POST /leads`'s verb at `at` (`now` too): a new
  lead of `profile` on `job`, its `applied` row written by the ledger.
  Answers the lead.
  """
  def apply_at(scope, job, profile, %DateTime{} = at) do
    {:ok, sheet} =
      Core.Leads.create(
        scope,
        %{"job_id" => job.id, "profile_id" => profile.id, "as" => "apply"},
        at
      )

    Data.Leads.get(Data.Scope.organisation_id(scope), sheet.id)
  end

  @doc "A lead verb (`Core.Leads.Act.run/6`) at `at`, `from` where the lead is. Answers the lead."
  def verb_at(scope, verb, lead, body, %DateTime{} = at) do
    lead = Data.Leads.reload(lead)
    from = %{"state" => to_string(lead.state), "stage" => lead.stage && lead.stage.key}
    {:ok, _sheet} = Act.run(scope, verb, lead.id, Map.put(body, "from", from), at)
    Data.Leads.reload(lead)
  end

  @doc """
  An employer's reply landing on `lead` at `at`, as `Core.Conversations.Record`
  writes it: the message (from a new contact, or `from_kind:`) and its
  `message_in` row. Answers the message.
  """
  def reply_at(scope, lead, %DateTime{} = at, attrs \\ []) do
    attrs = Map.new(attrs)
    kind = attrs[:from_kind] || :contact
    contact = if kind == :contact, do: Data.Fixtures.contact_fixture(scope, name: "Mei Chen")

    m =
      Data.Fixtures.message_fixture(scope,
        lead: lead,
        contact: contact,
        from_kind: kind,
        direction: :in,
        sent_at: at,
        body_text: attrs[:body_text] || "Thanks, let's talk."
      )

    _event =
      Ledger.record(
        scope,
        Data.Leads.reload(lead),
        :message_in,
        %{message_id: m.id, occurred_at: at},
        at
      )

    m
  end

  @doc "Changeset errors as %{field => [message]}, for readable assertions."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
