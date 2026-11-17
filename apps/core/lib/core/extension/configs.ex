defmodule Core.Extension.Configs do
  @moduledoc """
  The selector documents (AQ-05 §6.4, §11.4, QP5-21): each site's JSON in
  `apps/core/priv/extension/<site>.json`, **validated against contract 1**
  (`validate/1`), published as versions into `extension_configs` — v1 by the
  reference seed, a new version by `mix aq.ext_config` whenever a file's
  hash changed — and served live with its hash as the `ETag`.

  Contract 1, as pinned:

      {site, contract: 1, save_only?: bool,
       pages:        {<page_kind>: {url: [substring | "re:<regex>"], ready: [css]}},
       fields:       {<field key>: {on: <page_kind> | [<page_kind>], css: [css] (1–6),
                      read: "text" | "href" | "html" | "present" | "attr:<name>",
                      required: bool, all?: bool, match?: regex,
                      required_when?: {apply_kind: [apply kind]}}},
       identity:     {css: [css], read: "href" | "text"} (optional when save_only),
       confirmation: {on: <page_kind>, css: [css], read: "present"}?,
       apply:        {on: "job", easy_css?: [css], external_css?: [css]}?}

  A field key is a member of §11.3's `fields`, dotted for nesting
  (`title`, `upwork.proposals_text`, `upwork.client.rating_text`) — AQ-06
  §11.6 adds the `thread` page's (`other_profile_url`, `other_name`,
  `messages` and each message's `external_id`, `side`, `sent_text`,
  `text`); AQ-10 §11.4 adds the presence drafts, all optional
  (`thread.other_online`, `thread.other_last_seen_text`,
  `thread.other_active_text`); a page kind is `ext_page_kinds`'s, and every
  `on` names a page of the document.

  AQ-12 §11.4 adds, for Indeed, YC Work at a Startup and Wellfound:

  - `save_only` (a boolean, YC's and Wellfound's `true`): the site is read
    only on a press, so its document **may have no `identity`**; without
    it, `identity` stays required;
  - `identity.read: "text"` beside `"href"`: Indeed shows the signed-in
    account's email, not a profile link (`Utils.ChannelKey`'s
    `indeed:{email}`);
  - a field's `on` as one page kind or a list of them (Indeed's title,
    company and place are read on its job page and its post-apply page);
  - the sites' field keys: `indeed.easily_apply`,
    `indeed.responsive_employer`, `indeed.urgently_hiring`,
    `indeed.job_type_text`, `indeed.work_setting_text`; `yc.batch_text`,
    `yc.team_size_text`, `yc.stage_text`, `yc.experience_text`,
    `yc.visa_text`, `yc.equity_text`; `wellfound.stage_text`,
    `wellfound.remote_policy_text`, `wellfound.timezone_text`,
    `wellfound.visa_text`, `wellfound.equity_text`.

  AQ-12C §4.2 adds, both optional and backward compatible:

  - `match` on a field (or a message member): a regular expression, tested
    without regard to case. Each selector tries every element it finds, in
    order, and the first whose value matches wins; with a group, the value
    is the first group, trimmed; when none matches, the field is null (a
    miss, if required). A line is read by what it says, never by its
    position. One that doesn't compile is refused;
  - `required_when` on an optional field: `{"apply_kind": ["external_ats"]}`
    makes it a miss when it reads nothing and the apply kind read is one of
    those (LinkedIn's apply link on the company's site). Only `apply_kind`,
    only the reader's kinds (`in_platform_easy`, `external_ats`,
    `proposal`), and never on a field already `required`.
  """

  alias Core.Access
  alias Data.Extension, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @field_keys ~w(title company_name company_url location_text workplace_text employment_text
                 seniority_text salary_text posted_text applicants_text apply_kind apply_url
                 skills_text description_html is_promoted hiring_team_text bid_text
                 connects_spent_text
                 upwork.budget_text upwork.rate_text upwork.experience_text upwork.duration_text
                 upwork.hours_text upwork.connects_text upwork.proposals_text
                 upwork.last_viewed_text upwork.interviewing_text upwork.invites_text
                 upwork.unanswered_text upwork.hires_text
                 upwork.client.payment_verified upwork.client.rating_text
                 upwork.client.reviews_text upwork.client.location_text
                 upwork.client.local_time_text upwork.client.jobs_posted_text
                 upwork.client.hire_rate_text upwork.client.open_jobs_text
                 upwork.client.spent_text upwork.client.hires_text
                 upwork.client.active_hires_text upwork.client.avg_rate_text
                 upwork.client.member_since_text
                 other_profile_url other_name messages messages.external_id messages.side
                 messages.sent_text messages.text
                 thread.other_online thread.other_last_seen_text thread.other_active_text
                 indeed.easily_apply indeed.responsive_employer indeed.urgently_hiring
                 indeed.job_type_text indeed.work_setting_text
                 yc.batch_text yc.team_size_text yc.stage_text yc.experience_text yc.visa_text
                 yc.equity_text
                 wellfound.stage_text wellfound.remote_policy_text wellfound.timezone_text
                 wellfound.visa_text wellfound.equity_text)
  @top ~w(site contract save_only pages fields identity confirmation apply)
  @sites Vocabulary.ext_sites() |> Enum.map(&String.to_atom/1)
  @reads ~w(text href html present)
  # The apply kinds the extension's reader reads (`required_when`, AQ-12C §4.2).
  @apply_kinds ~w(in_platform_easy external_ats proposal)

  @doc "The field keys a document may read (§11.4)."
  def field_keys, do: @field_keys

  @doc "Where the repo's documents are: `core`'s `priv/extension`."
  @spec dir() :: Path.t()
  def dir, do: Application.app_dir(:core, "priv/extension")

  # ── The contract ────────────────────────────────────────────────────────────

  @doc """
  Whether a decoded document keeps contract 1: `:ok`, or `{:error,
  problems}`, each a path and what is wrong with it. Pure.

      iex> Core.Extension.Configs.validate(%{"site" => "upwork"})
      {:error, ["contract: is not 1", "pages: is missing", "fields: is missing", "identity: is missing"]}
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(%{} = doc) do
    pages = if is_map(doc["pages"]), do: Map.keys(doc["pages"]), else: []

    problems =
      List.flatten([
        unknown(doc, @top, ""),
        site(doc["site"]),
        if(doc["contract"] == 1, do: [], else: ["contract: is not 1"]),
        if(doc["save_only"] in [nil, true, false],
          do: [],
          else: ["save_only: is not true or false"]
        ),
        required(doc, "pages", &pages/1),
        required(doc, "fields", &fields(&1, pages)),
        if(doc["save_only"] == true,
          do: optional(doc, "identity", &identity/1),
          else: required(doc, "identity", &identity/1)
        ),
        optional(doc, "confirmation", &confirmation(&1, pages)),
        optional(doc, "apply", &apply_rule(&1, pages))
      ])

    if problems == [], do: :ok, else: {:error, problems}
  end

  def validate(_doc), do: {:error, ["the document is not a JSON object"]}

  @doc """
  A file's text for `site`, decoded and validated, and naming that site:
  `:ok` or `{:error, problems}`.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, [String.t()]}
  def check(site, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"site" => ^site} = doc} -> validate(doc)
      {:ok, %{} = doc} -> with :ok <- validate(doc), do: {:error, ["site: is not #{site}"]}
      {:ok, _other} -> {:error, ["the document is not a JSON object"]}
      {:error, error} -> {:error, ["not JSON: " <> Exception.message(error)]}
    end
  end

  defp site(site) do
    if site in Vocabulary.ext_sites(),
      do: [],
      else: ["site: is not one of #{Enum.join(Vocabulary.ext_sites(), ", ")}"]
  end

  defp required(doc, key, check) do
    case Map.fetch(doc, key) do
      {:ok, %{} = value} -> prefix(key, check.(value))
      {:ok, _other} -> ["#{key}: is not an object"]
      :error -> ["#{key}: is missing"]
    end
  end

  defp optional(doc, key, check) do
    case Map.fetch(doc, key) do
      :error -> []
      {:ok, nil} -> []
      {:ok, %{} = value} -> prefix(key, check.(value))
      {:ok, _other} -> ["#{key}: is not an object"]
    end
  end

  defp prefix(key, problems) do
    Enum.map(List.flatten(problems), fn
      ":" <> _rest = problem -> key <> problem
      problem -> "#{key}.#{problem}"
    end)
  end

  defp pages(pages) when pages == %{}, do: [": has no page"]
  defp pages(pages), do: Enum.map(pages, fn {kind, page} -> page(kind, page) end)

  defp page(kind, page) do
    cond do
      kind not in Vocabulary.ext_page_kinds() ->
        "#{kind}: is not a page kind"

      not is_map(page) ->
        "#{kind}: is not an object"

      true ->
        [
          unknown(page, ~w(url ready), kind <> "."),
          list(page["url"], "#{kind}.url", &url_rule/1, 1..20),
          css(page["ready"], "#{kind}.ready")
        ]
    end
  end

  defp fields(fields, _pages) when fields == %{}, do: [": has no field"]

  defp fields(fields, pages),
    do: Enum.map(fields, fn {key, field} -> field(key, field, pages) end)

  defp field(key, _field, _pages) when key not in @field_keys,
    do: "#{key}: is not a field of §11.3"

  defp field(key, field, _pages) when not is_map(field), do: "#{key}: is not an object"

  defp field(key, field, pages) do
    [
      unknown(field, ~w(on css read required all match required_when), key <> "."),
      on(field["on"], key, pages),
      css(field["css"], key <> ".css", 1..6),
      read(field["read"], key),
      if(is_boolean(field["required"]), do: [], else: ["#{key}.required: is not true or false"]),
      if(field["all"] in [nil, true, false], do: [], else: ["#{key}.all: is not true or false"]),
      if(Map.has_key?(field, "match"), do: match(field["match"], key), else: []),
      if(Map.has_key?(field, "required_when"),
        do: required_when(field["required_when"], field["required"], key),
        else: []
      )
    ]
  end

  # AQ-12C §4.2: a line read by what it says. The extension tests it without
  # regard to case, so it is compiled here the same way.
  defp match(source, key) when is_binary(source) do
    case Regex.compile(source, "i") do
      {:ok, _regex} when source != "" -> []
      _blank_or_wrong -> ["#{key}.match: is not a regular expression"]
    end
  end

  defp match(_source, key), do: ["#{key}.match: is not a regular expression"]

  # AQ-12C §4.2: an optional field required only when the apply kind read is
  # one of a list, `{"apply_kind": ["external_ats"]}`.
  defp required_when(_when, true, key),
    do: ["#{key}.required_when: is for a field not required"]

  defp required_when(when_, _required, key) when when_ == %{},
    do: ["#{key}.required_when: names nothing"]

  defp required_when(%{} = when_, _required, key) do
    Enum.flat_map(when_, fn
      {"apply_kind", kinds} -> apply_kinds(kinds, "#{key}.required_when.apply_kind")
      {other, _kinds} -> ["#{key}.required_when.#{other}: is not apply_kind"]
    end)
  end

  defp required_when(_when, _required, key), do: ["#{key}.required_when: is not an object"]

  defp apply_kinds([_ | _] = kinds, path) do
    for {kind, i} <- Enum.with_index(kinds),
        kind not in @apply_kinds,
        do: "#{path}[#{i}]: is not an apply kind"
  end

  defp apply_kinds(_kinds, path), do: ["#{path}: names no apply kind"]

  defp identity(identity) do
    [
      unknown(identity, ~w(css read), ""),
      css(identity["css"], "css"),
      if(identity["read"] in ["href", "text"], do: [], else: ["read: is not href or text"])
    ]
  end

  defp confirmation(c, pages) do
    [
      unknown(c, ~w(on css read), ""),
      on(c["on"], "on", pages, :bare),
      css(c["css"], "css"),
      if(c["read"] == "present", do: [], else: ["read: is not present"])
    ]
  end

  defp apply_rule(a, pages) do
    [
      unknown(a, ~w(on easy_css external_css), ""),
      if(a["on"] == "job", do: on("job", "on", pages, :bare), else: ["on: is not job"]),
      if(Map.has_key?(a, "easy_css"), do: css(a["easy_css"], "easy_css"), else: []),
      if(Map.has_key?(a, "external_css"), do: css(a["external_css"], "external_css"), else: [])
    ]
  end

  # A field reads on one page kind or several (AQ-12 §11.4); the
  # confirmation and the apply rule on one.
  defp on(kinds, where, pages, style \\ :field)

  defp on([_ | _] = kinds, where, pages, :field) do
    kinds
    |> Enum.with_index()
    |> Enum.flat_map(fn {kind, i} -> on(kind, "#{where}.on[#{i}]", pages, :bare) end)
  end

  defp on([], where, _pages, :field), do: ["#{where}.on: names no page"]

  defp on(kind, where, pages, style) do
    path = if style == :bare, do: where, else: where <> ".on"

    cond do
      not is_binary(kind) -> ["#{path}: is missing"]
      kind not in Vocabulary.ext_page_kinds() -> ["#{path}: is not a page kind"]
      kind not in pages -> ["#{path}: names no page of this document"]
      true -> []
    end
  end

  defp read("attr:" <> name, key) do
    if name =~ ~r/^[a-z][a-z0-9_:-]*$/, do: [], else: ["#{key}.read: is not attr:<name>"]
  end

  defp read(read, key) do
    if read in @reads,
      do: [],
      else: ["#{key}.read: is not text, href, html, present or attr:<name>"]
  end

  defp css(selectors, path, count \\ 1..20), do: list(selectors, path, &selector/1, count)

  defp list(values, path, check, first..last//_step) when is_list(values) do
    n = length(values)

    if n < first or n > last,
      do: ["#{path}: has #{n}, not #{first}–#{last}"],
      else: values |> Enum.with_index() |> Enum.flat_map(&item(&1, path, check))
  end

  defp list(_values, path, _check, _count), do: ["#{path}: is not a list"]

  defp item({value, i}, path, check) do
    case check.(value) do
      :ok -> []
      {:error, why} -> ["#{path}[#{i}]: #{why}"]
    end
  end

  defp selector(css) when is_binary(css) do
    cond do
      String.trim(css) == "" -> {:error, "is blank"}
      String.length(css) > 300 -> {:error, "is over 300 characters"}
      true -> :ok
    end
  end

  defp selector(_css), do: {:error, "is not a string"}

  defp url_rule("re:" <> source) do
    case Regex.compile(source) do
      {:ok, _regex} -> :ok
      {:error, _why} -> {:error, "is not a regular expression"}
    end
  end

  defp url_rule(text) when is_binary(text) do
    if String.trim(text) == "", do: {:error, "is blank"}, else: :ok
  end

  defp url_rule(_other), do: {:error, "is not a string"}

  defp unknown(map, known, path) do
    for key <- Map.keys(map), key not in known, do: "#{path}#{key}: is not in contract 1"
  end

  # ── Published versions ──────────────────────────────────────────────────────

  @doc """
  `GET /ext/v1/config?site`: the live document of `site`, `%{site, version,
  body, sha256, published_at}`. A site off `ext_sites` is a field error;
  one with nothing published, not found.
  """
  @spec live(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def live(%Scope{} = scope, site) do
    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, site} <- site_param(site) do
      case Store.live_config(site) do
        nil -> {:error, :not_found}
        config -> {:ok, config}
      end
    end
  end

  @doc """
  `GET /team/v1/extension/configs?$where`: every published version, newest
  first, for the system admin (404 for anyone else). `$where` is
  `Data.Filters.ExtensionConfigs`' (`site`, `version`).
  """
  @spec list(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, params) do
    with :ok <- Access.why_not(scope, :read_configs, :extension),
         do: Store.configs(params["$where"])
  end

  defp site_param(site) do
    if is_binary(site) and site in Vocabulary.ext_sites(),
      do: {:ok, Enum.find(@sites, &(Atom.to_string(&1) == site))},
      else:
        {:error,
         {:invalid, %{"site" => ["is one of #{Enum.join(Vocabulary.ext_sites(), ", ")}"]}}}
  end

  @doc """
  `mix aq.ext_config`: each site's file in `dir`, validated, published as a
  new version when its text is not the live one's. Answers one line per
  site: `{site, {:published, version}}`, `{site, {:unchanged, version}}`,
  `{site, :missing}`, or `{site, {:invalid, problems}}` (nothing published
  for that site). The system acting: no person, `via: system`.
  """
  @spec publish_files(Scope.t(), Path.t(), DateTime.t()) :: [{String.t(), term()}]
  def publish_files(%Scope{} = scope, dir, %DateTime{} = now) do
    :ok = Access.why_not(scope, :read_configs, :extension)

    for site <- Vocabulary.ext_sites() do
      path = Path.join(dir, site <> ".json")

      with {:ok, body} <- File.read(path),
           :ok <- check(site, body) do
        {site, publish(site, body, now)}
      else
        {:error, :enoent} -> {site, :missing}
        {:error, problems} when is_list(problems) -> {site, {:invalid, problems}}
        {:error, reason} -> {site, {:invalid, [inspect(reason)]}}
      end
    end
  end

  defp publish(site, body, now) do
    case Store.publish(site, body, now) do
      {:ok, {:published, config}} -> {:published, config.version}
      {:ok, {:unchanged, config}} -> {:unchanged, config.version}
      {:error, {:published_before, version}} -> {:published_before, version}
      {:error, changeset} -> {:invalid, [inspect(changeset.errors)]}
    end
  end
end
