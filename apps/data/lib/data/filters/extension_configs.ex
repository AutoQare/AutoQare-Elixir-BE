defmodule Data.Filters.ExtensionConfigs do
  @moduledoc """
  `GET /team/v1/extension/configs`' `$where` (AQ-11B §3 #12): every
  published version of the selector documents, newest first; the system
  admin's alone (`Core.Extension.Configs`).

  | Field | Operators | Is |
  |---|---|---|
  | `site` | `$EQUAL` `$IN` | the site the document reads (`ext_sites`) |
  | `version` | `$EQUAL` `$GTE` `$LTE` | the version number |
  """

  use FatEcto.Query.Dynamics.Buildable,
    filterable: [site: ["$EQUAL", "$IN"], version: ["$EQUAL", "$GTE", "$LTE"]],
    ignoreable: [site: ["", nil, []], version: ["", nil]]

  use Data.Filters
end
