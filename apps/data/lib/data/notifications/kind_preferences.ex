defmodule Data.Notifications.KindPreferences do
  @moduledoc """
  A person's switches per kind (AQ-10B §11.4, QP10b-3), storage only: one
  row per person and kind, written the first time a kind's switch
  changes. Which switches a kind shows and who may turn what off is
  `Core.Notifications.Settings`'s; how a row and the group's combine is
  `Core.Notifications.Channels`'.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.{Kind, KindPreference}
  alias Data.Repo

  @fields [:is_push_on, :is_email_on, :is_extension_on, :is_digest_on]

  @doc "The person's row for one kind, or `nil` (the kind's defaults)."
  @spec get(binary(), String.t()) :: KindPreference.t() | nil
  def get(user_id, kind_key),
    do: Repo.get_by(KindPreference, user_id: user_id, notification_kind_key: kind_key)

  @doc "The person's rows, by kind key."
  @spec for_user(binary()) :: %{String.t() => KindPreference.t()}
  def for_user(user_id) do
    from(p in KindPreference, where: p.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(&{&1.notification_kind_key, &1})
  end

  @doc "Writes the kind's switches (`%{push, email, extension, digest}`, every one)."
  @spec put(binary(), String.t(), map(), DateTime.t()) :: {:ok, KindPreference.t()}
  def put(user_id, kind_key, %{} = switches, %DateTime{} = now) do
    row = %{
      user_id: user_id,
      notification_kind_key: kind_key,
      is_push_on: switches.push,
      is_email_on: switches.email,
      is_extension_on: switches.extension,
      is_digest_on: switches.digest,
      updated_at: %{now | microsecond: {elem(now.microsecond, 0), 6}}
    }

    {1, _rows} =
      Repo.insert_all(KindPreference, [row],
        on_conflict: {:replace, @fields ++ [:updated_at]},
        conflict_target: [:user_id, :notification_kind_key]
      )

    {:ok, get(user_id, kind_key)}
  end

  @doc """
  Sets one channel on every row the person has for a group's kinds,
  to each kind's own default for it (`defaults`: `%{kind_key => boolean}`):
  what turning a group's switch back on does (AQ-10B §6).
  """
  @spec reset_channel(binary(), String.t(), atom(), %{String.t() => boolean()}, DateTime.t()) ::
          :ok
  def reset_channel(user_id, group_key, channel, defaults, %DateTime{} = now) do
    field = field(channel)
    now = %{now | microsecond: {elem(now.microsecond, 0), 6}}

    rows =
      from(p in KindPreference,
        join: k in Kind,
        on: k.key == p.notification_kind_key,
        where: p.user_id == ^user_id and k.notification_group_key == ^group_key
      )
      |> Repo.all()

    for row <- rows do
      value = Map.get(defaults, row.notification_kind_key, true)

      from(p in KindPreference,
        where: p.user_id == ^user_id and p.notification_kind_key == ^row.notification_kind_key
      )
      |> Repo.update_all(set: [{field, value}, {:updated_at, now}])
    end

    :ok
  end

  @doc "The kinds in which the person turned `channel` off."
  @spec off_kinds(binary(), :push | :email | :extension | :digest) :: [String.t()]
  def off_kinds(user_id, channel) do
    field = field(channel)

    from(p in KindPreference,
      where: p.user_id == ^user_id and field(p, ^field) == false,
      select: p.notification_kind_key
    )
    |> Repo.all()
  end

  @doc "The kinds in which the person turned `channel` on (an offered channel switched on)."
  @spec on_kinds(binary(), :push | :email | :extension | :digest) :: [String.t()]
  def on_kinds(user_id, channel) do
    field = field(channel)

    from(p in KindPreference,
      where: p.user_id == ^user_id and field(p, ^field) == true,
      select: p.notification_kind_key
    )
    |> Repo.all()
  end

  defp field(:push), do: :is_push_on
  defp field(:email), do: :is_email_on
  defp field(:extension), do: :is_extension_on
  defp field(:digest), do: :is_digest_on
end
