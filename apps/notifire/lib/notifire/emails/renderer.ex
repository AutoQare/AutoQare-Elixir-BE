defmodule Notifire.Emails.Renderer do
  @moduledoc """
  Joins the layout and one kind's body (AQ-10B §7, §11.4; MyQuriosity's
  `Core.Emails.Renderer`, compiled instead of evaluated): **HTML and plain
  text, always both**, from `Notifire.Emails.Templates`.

  - `content` — what the kind's templates read: `first_name`, `title`,
    `body`, `url`, `facts` (`[{label, value}]`), and whatever a kind adds
    (the digest's `items`, a customer with no login's `no_login`);
  - `chrome` — what the layout reads: `org_name`, `logo_url`, `why`,
    `manage_url`, `unsubscribe_url` and `group_label` (none on a locked or
    account mail), `locked_note`, `help_email`, `postal_address`.

  The subject is the kind's `subject.txt` on one line, at most 70
  characters (cut with "…"); the preheader the first words of the body.
  Answers `%{subject, html, text, preheader}`.
  """

  alias Notifire.Emails.Templates

  @subject_max 70
  @preheader_max 110

  @content_defaults %{
    first_name: nil,
    title: "",
    body: nil,
    url: nil,
    facts: [],
    items: [],
    no_login: false
  }

  @chrome_defaults %{
    org_name: "AutoQare",
    logo_url: nil,
    why: "This is about your AutoQare account.",
    manage_url: nil,
    unsubscribe_url: nil,
    group_label: nil,
    locked_note: nil,
    help_email: nil,
    postal_address: nil
  }

  @doc ~s|Renders `kind` for `audience` (`"staff"` or `"customer"`).|
  @spec render(String.t(), String.t(), map(), map()) :: %{
          subject: String.t(),
          html: String.t(),
          text: String.t(),
          preheader: String.t()
        }
  def render(kind, audience, content, chrome) do
    content = Map.merge(@content_defaults, Map.new(content))
    chrome = Map.merge(@chrome_defaults, Map.new(chrome))

    subject = kind |> Templates.render(audience, "subject.txt", content) |> one_line(@subject_max)
    preheader = one_line(content.body || content.title, @preheader_max)
    inner_html = Templates.render(kind, audience, "body.html", content)
    inner_text = kind |> Templates.render(audience, "body.text", content) |> tidy()

    layout =
      Map.merge(chrome, %{
        subject: subject,
        preheader: preheader,
        inner: inner_html,
        logo_url: chrome.logo_url || logo_url()
      })

    %{
      subject: subject,
      html: Templates.layout_html(layout),
      text: layout |> Map.put(:inner, inner_text) |> Templates.layout_text() |> tidy(),
      preheader: preheader
    }
  end

  @doc """
  A kind's push words from its `push.md` (AQ-10B §7.2): the first line is
  the title, the rest the body. Answers `%{title, body}`.
  """
  @spec push(String.t(), String.t(), map()) :: %{title: String.t(), body: String.t() | nil}
  def push(kind, audience, content) do
    content = Map.merge(@content_defaults, Map.new(content))

    case kind |> Templates.render(audience, "push.md", content) |> String.split("\n", parts: 2) do
      [title] -> %{title: String.trim(title), body: nil}
      [title, body] -> %{title: String.trim(title), body: presence(String.trim(body))}
    end
  end

  @doc """
  One line, at most `max` characters, cut at a word with "…".

      iex> Notifire.Emails.Renderer.one_line("  Interview with\\nCorvid  ", 70)
      "Interview with Corvid"
      iex> Notifire.Emails.Renderer.one_line(String.duplicate("word ", 20), 20)
      "word word word…"
  """
  @spec one_line(String.t() | nil, pos_integer()) :: String.t()
  def one_line(nil, _max), do: ""

  def one_line(text, max) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= max do
      text
    else
      cut = String.slice(text, 0, max - 1)

      cut =
        case String.split(cut, " ") do
          [_one] -> cut
          words -> words |> Enum.drop(-1) |> Enum.join(" ")
        end

      String.trim_trailing(cut, " ") <> "…"
    end
  end

  @doc "The mark's PNG, hosted by the console (`config :notifire, :logo_url` overrides)."
  @spec logo_url() :: String.t()
  def logo_url do
    Application.get_env(:notifire, :logo_url) ||
      Keyword.get(
        Application.get_env(:notifire, :app_urls, []),
        :console,
        "http://localhost:5800"
      ) <>
        "/icon-192.png"
  end

  # Blank lines at most two in a row, no trailing spaces.
  defp tidy(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
