defmodule Core.Imports.Values do
  @moduledoc """
  A row's cells read through the mapping into its `values` (AQ-12 §11.4),
  pure: every lookup — the team's people and profiles, the skills, the
  tab's choices, *today* — is handed in as `ctx`. Answers `{values,
  reasons}`; a reason is `%{"code", "words"}`, and `errors/1` says which
  of them keep a row from being imported.

  - `date` in the import's order (`Core.Imports.Dates`): `bad_date`;
  - `job_url` through `Utils.JobKey` (`key`, `source`): `bad_link` when it
    doesn't parse; a Fiverr link has no key and is allowed only in the
    *jobs* kind (`fiverr: true`);
  - `profile`: the column's (a profile title, or "Customer · Title"), else
    the tab's; none or unknown is `no_profile`;
  - `applied_by`: a team member by name or email, the closest name offered
    (`unknown_person`, "Unknown name “Fazia”. Fiza?"); "direct" or blank is
    the tab's applier;
  - `stack`: each through the skills vocabulary and its aliases ("Go" →
    Golang); the rest is a warning (`unknown_stack`) and goes to the
    description;
  - `country` / `worldwide`: the job's ISO countries, and remote with its
    scope ("Yes" → worldwide);
  - a `status` off §3.3's table is a warning (`unknown_status`).
  """

  alias Core.Imports.{Dates, Statuses}
  alias Core.Ingest.Extension.Read
  alias Core.Jobs.Link

  @errors ~w(bad_date bad_link no_profile unknown_person no_title no_name bad_handle)
  @yes ~w(yes y true 1 worldwide global anywhere remote)
  @no ~w(no n false 0)
  @direct ~w(direct self me)

  # Spellings the skills vocabulary doesn't hold as names.
  @skill_aliases %{
    "golang" => "go",
    "go lang" => "go",
    "node" => "node js",
    "nodejs" => "node js",
    "js" => "javascript",
    "ts" => "typescript",
    "reactjs" => "react",
    "react js" => "react",
    "vuejs" => "vue js",
    "vue" => "vue js",
    "postgres" => "postgresql",
    "k8s" => "kubernetes",
    "ror" => "ruby on rails",
    "rails" => "ruby on rails",
    "py" => "python",
    "dotnet" => "net"
  }

  @doc "The codes that keep a row from being imported."
  @spec error_codes() :: [String.t()]
  def error_codes, do: @errors

  @doc "The reasons among `reasons` that are errors."
  @spec errors([map()]) :: [map()]
  def errors(reasons), do: Enum.filter(reasons, &(&1["code"] in @errors))

  @doc """
  `{values, reasons}` for a row's `cells` (header → text) through `ctx`:
  `%{kind, mapping, date_order, today, members: [%{id, name, email}],
  profiles: [%{id, title, customer_name}], skills: [%{id, name}], tab:
  %{profile_id, applier_user_id}}`.
  """
  @spec read(map(), map()) :: {map(), [map()]}
  def read(%{kind: kind} = ctx, cells) do
    by_field = by_field(ctx.mapping, cells)
    one = fn field -> by_field |> Map.get(field, []) |> Enum.join(" ") |> Utils.presence() end

    case to_string(kind) do
      "contacts" -> contact(one)
      kind -> job_row(ctx, kind, one)
    end
  end

  # Each field's cells (by header, when two columns map to one field).
  defp by_field(mapping, cells) do
    cells
    |> Enum.sort_by(fn {header, _value} -> header end)
    |> Enum.reduce(%{}, fn {header, value}, acc ->
      case Map.get(mapping, header, "ignore") do
        "ignore" -> acc
        field -> Map.update(acc, field, [value], &(&1 ++ [value]))
      end
    end)
  end

  # ── Applications and jobs ───────────────────────────────────────────────────

  defp job_row(ctx, kind, one) do
    {values, reasons} =
      {%{
         "title" => one.("title"),
         "company" => one.("company"),
         "salary" => one.("salary"),
         "platform" => one.("platform"),
         "company_type" => one.("company_type"),
         "notes" => one.("notes"),
         "recruiter" => recruiter(one)
       }, []}
      |> link(one.("job_url"), kind)
      |> place(one.("country"), one.("worldwide"))
      |> stack(one.("stack"), ctx.skills)

    if kind == "applications" do
      {values, reasons}
      |> date(one.("date"), ctx)
      |> profile(one.("profile"), ctx)
      |> applier(one.("applied_by"), ctx)
      |> status(one.("status"))
    else
      {values, reasons}
    end
  end

  defp link({values, reasons}, nil, _kind),
    do: {values, reasons ++ [reason("bad_link", "No job link.")]}

  defp link({values, reasons}, url, kind) do
    values = Map.put(values, "link_written", url)

    cond do
      Link.fiverr_link?(url) and kind == "jobs" ->
        {Map.merge(values, %{"job_url" => Link.web_link(url), "fiverr" => true}), reasons}

      Link.fiverr_link?(url) ->
        {values,
         reasons ++
           [reason("bad_link", "A Fiverr link has no job to match; import it as a job list.")]}

      true ->
        case Link.parse(url) do
          {:ok, link} ->
            {Map.merge(values, %{
               "job_url" => link.url,
               "key" => link.key,
               "source" => to_string(link.source)
             }), reasons}

          {:error, _invalid} ->
            {values, reasons ++ [reason("bad_link", "#{url} isn't a job link.")]}
        end
    end
  end

  defp place({values, reasons}, country, worldwide) do
    countries = if country, do: Read.countries(country), else: []

    word = worldwide && String.downcase(worldwide)

    worldwide =
      cond do
        word in @yes -> true
        word in @no -> false
        true -> nil
      end

    {Map.merge(values, %{"country" => country, "countries" => countries, "worldwide" => worldwide}),
     reasons}
  end

  defp stack({values, reasons}, nil, _skills),
    do: {Map.merge(values, %{"skill_ids" => [], "unknown_stack" => []}), reasons}

  defp stack({values, reasons}, text, skills) do
    by_name = Map.new(skills, &{normal(&1.name), &1.id})

    {found, missed} =
      text
      |> String.split(~r/[,;\/|&]|\band\b/u, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&normal/1)
      |> Enum.split_with(&Map.has_key?(by_name, skill_key(&1)))

    reasons =
      if missed == [],
        do: reasons,
        else:
          reasons ++
            [
              reason(
                "unknown_stack",
                "Not in the skills list: #{Enum.join(missed, ", ")}. Kept in the description."
              )
            ]

    {Map.merge(values, %{
       "skill_ids" => found |> Enum.map(&Map.fetch!(by_name, skill_key(&1))) |> Enum.uniq(),
       "unknown_stack" => missed
     }), reasons}
  end

  defp skill_key(name), do: Map.get(@skill_aliases, normal(name), normal(name))

  defp normal(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp recruiter(one) do
    %{
      "name" => one.("recruiter_name"),
      "linkedin" => one.("recruiter_linkedin"),
      "email" => one.("recruiter_email"),
      "personal_email" => one.("recruiter_personal_email")
    }
  end

  defp date({values, reasons}, text, ctx) do
    case Dates.read(text, ctx.date_order, ctx.today) do
      {:ok, date} -> {Map.put(values, "date", Date.to_iso8601(date)), reasons}
      {:error, words} -> {values, reasons ++ [reason("bad_date", words)]}
    end
  end

  defp profile({values, reasons}, written, ctx) do
    case written do
      nil -> tab_profile({values, reasons}, ctx)
      name -> named_profile({values, reasons}, name, ctx.profiles)
    end
  end

  defp tab_profile({values, reasons}, %{tab: %{profile_id: id}, profiles: profiles})
       when is_binary(id) do
    if Enum.any?(profiles, &(&1.id == id)),
      do: {Map.put(values, "profile_id", id), reasons},
      else:
        {values,
         reasons ++ [reason("no_profile", "The tab's profile is no longer one this team serves.")]}
  end

  defp tab_profile({values, reasons}, _ctx),
    do: {values, reasons ++ [reason("no_profile", "No profile: choose one for the tab.")]}

  defp named_profile({values, reasons}, name, profiles) do
    wanted = normal(name)

    case Enum.filter(
           profiles,
           &(normal(&1.title) == wanted or normal("#{&1.customer_name} #{&1.title}") == wanted)
         ) do
      [profile] ->
        {Map.put(values, "profile_id", profile.id), reasons}

      [_one, _two | _rest] ->
        {values, reasons ++ [reason("no_profile", "More than one profile is called “#{name}”.")]}

      [] ->
        {values, reasons ++ [reason("no_profile", "Unknown profile “#{name}”.")]}
    end
  end

  defp applier({values, reasons}, written, ctx) do
    tab = ctx.tab[:applier_user_id]

    cond do
      is_nil(written) or String.downcase(written) in @direct ->
        if tab,
          do: {Map.put(values, "applier_user_id", tab), reasons},
          else:
            {values,
             reasons ++ [reason("unknown_person", "Nobody applied: choose who for the tab.")]}

      member = find_member(written, ctx.members) ->
        {Map.put(values, "applier_user_id", member.id), reasons}

      true ->
        {values, reasons ++ [reason("unknown_person", unknown_words(written, ctx.members))]}
    end
  end

  defp find_member(written, members) do
    wanted = normal(written)

    Enum.find(
      members,
      &(normal(&1.name) == wanted or String.downcase(&1.email || "") == String.downcase(written))
    ) ||
      Enum.find(members, &(first_name(&1.name) == wanted))
  end

  defp first_name(name), do: name |> normal() |> String.split(" ") |> hd()

  defp unknown_words(written, members) do
    best =
      members
      |> Enum.map(&{&1, String.jaro_distance(normal(written), first_name(&1.name))})
      |> Enum.max_by(fn {_member, score} -> score end, fn -> nil end)

    case best do
      {member, score} when score >= 0.75 ->
        "Unknown name “#{written}”. #{member.name |> String.split(" ") |> hd()}?"

      _none ->
        "Unknown name “#{written}”."
    end
  end

  defp status({values, reasons}, status) do
    values = Map.put(values, "status", status)

    if Statuses.known?(status),
      do: {values, reasons},
      else:
        {values,
         reasons ++ [reason("unknown_status", "Unknown status “#{status}”: read as none.")]}
  end

  # ── Contacts ────────────────────────────────────────────────────────────────

  defp contact(one) do
    values = %{
      "name" => one.("name"),
      "title" => one.("title"),
      "company" => one.("company"),
      "email" => one.("email"),
      "linkedin" => one.("linkedin"),
      "phone" => one.("phone"),
      "notes" => one.("notes")
    }

    if values["name"],
      do: {values, []},
      else: {values, [reason("no_name", "No name.")]}
  end

  @doc "A reason, as a row keeps it."
  @spec reason(String.t(), String.t()) :: map()
  def reason(code, words), do: %{"code" => code, "words" => words}
end
