defmodule Data.Organisations.OrganisationSettings do
  @moduledoc """
  The prototype's timings as data (AQ-01 §4.2), 1:1 with the organisation.
  `defaults/1` is what a reader gets when no row exists. P10b (AQ-10B
  §11.4): `help_email` and `postal_address`, for every email's footer.
  P11 (AQ-11 §7.4): `working_days`, the ISO weekdays that carry a daily
  target (Monday to Friday by default).
  """

  use Data.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  @fields ~w(follow_up_gap_days max_follow_ups no_response_days similar_window_days
             inactivity_days purge_after_days warning_days observation_retention_days)a

  schema "organisation_settings" do
    field(:organisation_id, :binary_id, primary_key: true)
    field(:follow_up_gap_days, :integer, default: 3)
    field(:max_follow_ups, :integer, default: 2)
    field(:no_response_days, :integer, default: 14)
    field(:similar_window_days, :integer, default: 14)
    field(:inactivity_days, :integer, default: 90)
    field(:purge_after_days, :integer, default: 90)
    field(:warning_days, :integer, default: 7)
    field(:observation_retention_days, :integer, default: 180)
    field(:help_email, :string)
    field(:postal_address, :string)
    field(:working_days, {:array, :integer}, default: [1, 2, 3, 4, 5])

    timestamps()
  end

  @texts ~w(help_email postal_address)a
  @lists ~w(working_days)a

  @doc "The settable day fields, for views and the context."
  def fields, do: @fields

  @doc "The settable text fields (P10b): the footer's help address and postal address."
  def texts, do: @texts

  @doc "The settable lists (P11): `working_days`."
  def lists, do: @lists

  @doc "The code defaults, as a row that was never written."
  @spec defaults(binary()) :: t()
  def defaults(organisation_id), do: %__MODULE__{organisation_id: organisation_id}

  def changeset(settings, attrs) do
    changeset =
      settings
      |> cast(attrs, [:organisation_id | @fields ++ @texts ++ @lists])
      |> update_change(:help_email, &trim/1)
      |> update_change(:postal_address, &trim/1)
      |> validate_required([:organisation_id | @fields])
      |> validate_length(:help_email, max: 254)
      |> validate_format(:help_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
        message: "is not an email address"
      )
      |> validate_length(:postal_address, max: 500)
      |> check_constraint(:help_email, name: :help_email_short)
      |> check_constraint(:postal_address, name: :postal_address_short)
      |> validate_required([:working_days])
      |> validate_change(:working_days, &weekdays/2)
      |> update_change(:working_days, &Enum.sort/1)
      |> check_constraint(:working_days, name: :working_days_known)
      |> foreign_key_constraint(:organisation_id)

    Enum.reduce(@fields, changeset, fn field, acc ->
      acc
      |> validate_number(field, greater_than_or_equal_to: 1, less_than_or_equal_to: 365)
      |> check_constraint(field, name: :"#{field}_in_range")
    end)
  end

  # ISO weekdays, each once: 1 Monday … 7 Sunday.
  defp weekdays(:working_days, days) do
    cond do
      Enum.any?(days, &(&1 not in 1..7)) ->
        [working_days: "are ISO weekdays, 1 Monday to 7 Sunday"]

      length(Enum.uniq(days)) != length(days) ->
        [working_days: "has a day twice"]

      true ->
        []
    end
  end

  # `nil` (or blank, which the cast makes `nil`) clears the field.
  defp trim(nil), do: nil
  defp trim(text) when is_binary(text), do: String.trim(text)
end
