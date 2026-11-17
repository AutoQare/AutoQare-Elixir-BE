defmodule Data.Imports.Import do
  @moduledoc """
  An import (AQ-12 §3, §11.4): one uploaded file brought into one team.
  `tabs` (`[%{"name", "rows", "profile_id", "applier_user_id",
  "include"}]`), `mapping` (`%{header => field}`) and `counts` are JSON
  with string keys; `state` moves only through `Core.Imports`' verbs and
  background jobs. The CHECKs in the migration hold the shape.
  """

  use Data.Schema

  alias Data.Vocabulary

  @kinds Vocabulary.import_kinds() |> Enum.map(&String.to_atom/1)
  @states Vocabulary.import_states() |> Enum.map(&String.to_atom/1)
  @date_orders Vocabulary.date_orders() |> Enum.map(&String.to_atom/1)

  @create ~w(organisation_id team_id created_by_user_id media_id file_name kind state)a
  @update ~w(state tabs mapping date_order overwrite counts progress error_text checked_at
             imported_at undo_until undone_at)a

  @type t :: %__MODULE__{}

  schema "imports" do
    field(:file_name, :string)
    field(:kind, Ecto.Enum, values: @kinds)
    field(:state, Ecto.Enum, values: @states, default: :reading)
    field(:tabs, {:array, :map}, default: [])
    field(:mapping, :map, default: %{})
    field(:date_order, Ecto.Enum, values: @date_orders, default: :day_month)
    field(:overwrite, :boolean, default: false)
    field(:counts, :map, default: %{})
    field(:progress, :integer, default: 0)
    field(:error_text, :string)
    field(:checked_at, :utc_datetime_usec)
    field(:imported_at, :utc_datetime_usec)
    field(:undo_until, :utc_datetime_usec)
    field(:undone_at, :utc_datetime_usec)

    belongs_to(:organisation, Data.Organisations.Organisation)
    belongs_to(:team, Data.Teams.Team)
    belongs_to(:created_by_user, Data.Accounts.User)
    belongs_to(:media, Data.Files.Media)

    has_many(:rows, Data.Imports.Row)

    timestamps()
  end

  @doc "A new import, `reading` its file."
  def create_changeset(import, attrs) do
    import
    |> cast(attrs, @create)
    |> validate_required([:organisation_id, :team_id, :file_name, :kind])
    |> update_change(:file_name, &(&1 && String.slice(String.trim(&1), 0, 255)))
    |> rules()
  end

  @doc "What the steps and the background jobs move."
  def changeset(import, attrs) do
    import
    |> cast(attrs, @update)
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> rules()
  end

  defp rules(changeset) do
    changeset
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:state, name: :state_known)
    |> check_constraint(:date_order, name: :date_order_known)
    |> check_constraint(:progress, name: :progress_range)
    |> check_constraint(:file_name, name: :file_name_present)
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:media_id)
  end
end
