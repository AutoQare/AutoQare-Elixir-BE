defmodule Data.Repo.Migrations.CreateCompanies do
  use Ecto.Migration

  @moduledoc """
  The companies jobs belong to (AQ-03 §5.1, QP3-6): chosen or added from the
  job form, matched by name and domain. One company per name in an
  organisation: `name_normalized` (lower, unaccented, trimmed — made by
  `Data.Companies.Company`, as P1's `handle_normalized` is) carries the
  unique index, and a trigram index on it serves the picker and the similar
  check. The companies list, contacts and company merge are P6's.

  **P10 (AQ-10 §6.3, QP10-7):** `time_zone` (an IANA name) with
  `time_zone_source` ∈ `upwork · manual`: read from an Upwork client's
  local time on a capture, or set by hand, which wins. Both or neither.
  """

  @zone_sources ~w(upwork manual)

  def change do
    create table(:companies, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:name, :string, null: false)
      add(:name_normalized, :string, null: false)
      add(:domain, :citext)
      add(:website_url, :text)
      add(:linkedin_url, :text)
      add(:size_band, :string)
      add(:industry, :string)
      add(:hq_country, :string)
      add(:notes_md, :text)
      add(:time_zone, :text)
      add(:time_zone_source, :text)
      add(:created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:companies, :name_present, check: "btrim(name) <> ''"))

    create(
      constraint(:companies, :size_band_known,
        check:
          "size_band IS NULL OR size_band IN ('1_10','11_50','51_200','201_500','501_1000'," <>
            "'1001_5000','5001_plus')"
      )
    )

    create(
      constraint(:companies, :hq_country_iso,
        check: "hq_country IS NULL OR hq_country ~ '^[A-Z]{2}$'"
      )
    )

    create(
      constraint(:companies, :time_zone_source_known,
        check: "time_zone_source IS NULL OR time_zone_source IN (#{list(@zone_sources)})"
      )
    )

    create(
      constraint(:companies, :time_zone_with_source,
        check: "(time_zone IS NULL) = (time_zone_source IS NULL)"
      )
    )

    create(unique_index(:companies, [:organisation_id, :name_normalized]))

    create(
      unique_index(:companies, [:organisation_id, :domain],
        where: "domain IS NOT NULL",
        name: :companies_organisation_id_domain_index
      )
    )

    create(
      index(:companies, ["name_normalized gin_trgm_ops"],
        using: :gin,
        name: :companies_name_normalized_trgm_index
      )
    )

    create(index(:companies, [:created_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON companies " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON companies"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
