defmodule Data.Skills do
  @moduledoc """
  The skills vocabulary (AQ-01 §4.3, QP1-4). Storage only; `Data.Seeds.Skills`
  loads the production list through `upsert/1`, staff add through
  `Core.Customers.Skills`.
  """

  import Ecto.Query, warn: false

  alias Data.Customers.Skill
  alias Data.Repo

  @spec get(binary(), binary()) :: Skill.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Skill, id: uuid, organisation_id: organisation_id)
      :error -> nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc """
  `GET /skills`: an organisation's live skills by category then name,
  narrowed by `where` (the list's `$where`, `Data.Filters.Skills`: `q`,
  `category`): `{:ok, skills}`, or the 422 `invalid_filter`.
  """
  @spec filtered(binary(), term()) :: {:ok, [Skill.t()]} | {:error, term()}
  def filtered(organisation_id, where) do
    base =
      from(s in Skill,
        where: s.organisation_id == ^organisation_id and is_nil(s.archived_at),
        order_by: [asc: s.category, asc: s.name]
      )

    with {:ok, query} <- Data.Filters.where(base, Data.Filters.Skills, where),
         do: {:ok, Repo.all(query)}
  end

  @doc """
  An organisation's skills by category then name, for a reader other than
  the list: `ids` narrows to some, `include_archived` keeps the archived.
  """
  @spec list(binary(), keyword()) :: [Skill.t()]
  def list(organisation_id, opts \\ []) do
    query =
      from(s in Skill,
        where: s.organisation_id == ^organisation_id,
        order_by: [asc: s.category, asc: s.name]
      )

    query =
      case Keyword.get(opts, :ids) do
        nil -> query
        ids -> where(query, [s], s.id in ^ids)
      end

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [s], is_nil(s.archived_at))

    Repo.all(query)
  end

  @spec create(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Skill{} |> Skill.changeset(attrs) |> Repo.insert()

  @doc "Inserts the skill unless its slug exists in the organisation. Answers `:inserted` or `:kept`."
  @spec upsert(map()) :: {:ok, :inserted | :kept} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    changeset = Skill.changeset(%Skill{}, attrs)
    slug = Ecto.Changeset.get_field(changeset, :slug)
    organisation_id = Ecto.Changeset.get_field(changeset, :organisation_id)

    if Repo.exists?(
         from(s in Skill, where: s.organisation_id == ^organisation_id and s.slug == ^slug)
       ) do
      {:ok, :kept}
    else
      with {:ok, _skill} <- Repo.insert(changeset), do: {:ok, :inserted}
    end
  end

  @spec archive(Skill.t(), DateTime.t()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Skill{} = skill, %DateTime{} = at),
    do: skill |> Ecto.Changeset.change(archived_at: at) |> Repo.update()
end
