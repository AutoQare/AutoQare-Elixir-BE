defmodule Notifire.Emails.Templates do
  @moduledoc """
  Every email template, **compiled at build time** (AQ-10B §7.2, §11.4):
  each file under `priv/emails/` becomes a function through
  `EEx.function_from_file`, so nothing is read or evaluated at a send.

  - `layout.{html,text}.eex`: the shell, header and footer;
  - `<group>/<kind>-for-<staff|customer>-{subject.txt, body.html,
    body.text, push.md}.eex`: one kind's words for one audience (myqampus's
    naming; `<kind>` is the key after its group: `tasks/assigned-for-…` is
    `tasks.assigned`), P1's mails among them under `account/`;
  - `_fallback/`: a kind with no template of its own.

  **A missing template fails the build**: every kind the seed lets email
  an audience (its channels or its offered ones) must have its four files
  for that audience, and each kind's set must be whole. Templates call
  `Notifire.Emails.Html` (imported) and escape every value they show.
  """

  import Notifire.Emails.Html, warn: false

  require EEx

  alias Data.Seeds.Notifications, as: Seed

  @root Path.expand("../../../priv/emails", __DIR__)
  @parts ~w(subject.txt body.html body.text push.md)
  @paths Path.wildcard(Path.join(@root, "**/*.eex"))
  @paths_hash :erlang.md5(Enum.join(@paths, "\n"))

  @doc false
  def __mix_recompile__?,
    do: :erlang.md5(Enum.join(Path.wildcard(Path.join(@root, "**/*.eex")), "\n")) != @paths_hash

  EEx.function_from_file(:def, :layout_html, Path.join(@root, "layout.html.eex"), [:assigns])
  EEx.function_from_file(:def, :layout_text, Path.join(@root, "layout.text.eex"), [:assigns])

  @templates (for path <- @paths,
                  relative = Path.relative_to(path, @root),
                  [group, file] <- [Path.split(relative)],
                  group not in ["parts", "_fallback"],
                  [_all, tail, audience, part] <-
                    [Regex.run(~r/^([a-z0-9_]+)-for-(staff|customer)-(.+)\.eex$/, file)],
                  part in @parts do
                {{"#{group}.#{tail}", audience, part}, path}
              end)

  for {{kind, audience, part}, path} <- @templates do
    EEx.function_from_file(:defp, :"t_#{:erlang.phash2({kind, audience, part})}", path, [
      :assigns
    ])
  end

  for part <- @parts do
    EEx.function_from_file(
      :defp,
      :"fallback_#{String.replace(part, ".", "_")}",
      Path.join([@root, "_fallback", "#{part}.eex"]),
      [:assigns]
    )
  end

  for {{kind, audience, part}, _path} <- @templates do
    defp dispatch(unquote(kind), unquote(audience), unquote(part), assigns),
      do: unquote(:"t_#{:erlang.phash2({kind, audience, part})}")(assigns)
  end

  for part <- @parts do
    defp dispatch(_kind, _audience, unquote(part), assigns),
      do: unquote(:"fallback_#{String.replace(part, ".", "_")}")(assigns)
  end

  # ── Whole sets, and every kind that emails ──────────────────────────────────

  @sets @templates
        |> Enum.map(fn {{kind, audience, _part}, _path} -> {kind, audience} end)
        |> Enum.uniq()

  for {kind, audience} <- @sets,
      part <- @parts,
      not Enum.any?(@templates, fn {key, _path} -> key == {kind, audience, part} end) do
    raise CompileError,
      description: "email template #{kind} for #{audience} has no #{part}.eex",
      file: __ENV__.file
  end

  @emailing for {key, staff, customer} <- Seed.kinds(),
                {audience, channels, customer?} <- [
                  {"staff", staff, false},
                  {"customer", customer || staff, true}
                ],
                channels != [],
                "email" in channels or "email" in Seed.offered(key, customer?),
                do: {key, audience}

  for {kind, audience} <- @emailing, {kind, audience} not in @sets do
    raise CompileError,
      description: "#{kind} emails the #{audience} but has no template for them",
      file: __ENV__.file
  end

  @doc "Every `{kind, audience}` with its own templates, in order."
  @spec sets() :: [{String.t(), String.t()}]
  def sets, do: Enum.sort(@sets)

  @doc "Every `{kind, audience}` the seed lets email (each has its templates)."
  @spec emailing() :: [{String.t(), String.t()}]
  def emailing, do: @emailing

  @doc ~s|Whether `kind` has its own templates for `audience` (`"staff"` or `"customer"`).|
  @spec has?(String.t(), String.t()) :: boolean()
  def has?(kind, audience), do: {kind, audience} in @sets

  @doc """
  Renders one part (`"subject.txt"`, `"body.html"`, `"body.text"`,
  `"push.md"`) of `kind` for `audience` with `assigns`; the fallback's
  when the kind has none.
  """
  @spec render(String.t(), String.t(), String.t(), map()) :: String.t()
  def render(kind, audience, part, assigns) when part in @parts,
    do: dispatch(kind, audience, part, assigns)
end
