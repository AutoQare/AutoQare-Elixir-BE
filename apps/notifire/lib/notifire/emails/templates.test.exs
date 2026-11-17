defmodule Notifire.Emails.TemplatesTest do
  @moduledoc """
  A test per email template (AQ-10B §7.3): each kind × audience renders
  through the layout, its subject fits on one line under 70 characters,
  the plain text has the link and the footer's *Manage notifications*
  and unsubscribe, and nothing a customer or recruiter typed reaches the
  HTML unescaped. Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Notifire.Emails.{Renderer, Templates}

  @evil "<script>alert('x')</script>"
  @url "http://localhost:5800/leads/7?n=1"
  @manage "http://localhost:5800/notifications?sheet=settings"
  @unsubscribe "http://localhost:5800/unsubscribe?token=t0k3n"

  defp content do
    %{
      first_name: @evil,
      title: "#{@evil} replied on “Backend Developer · Corvid Security”, and more words to cut",
      body: "#{@evil} <b>bold</b> & more",
      url: @url,
      facts: [{"Company", @evil}, {"Stage", "Technical interview 1"}],
      items: [@evil, "Due tomorrow"],
      expires_on: "21 Nov",
      no_login: true
    }
  end

  defp chrome do
    %{
      org_name: "Evil & <Co>",
      why: @evil,
      manage_url: @manage,
      unsubscribe_url: @unsubscribe,
      group_label: "Leads",
      help_email: "help@northwind.example",
      postal_address: @evil
    }
  end

  test "every kind the seed lets email has its own templates for that audience" do
    for set <- Templates.emailing(), do: assert(set in Templates.sets(), inspect(set))
  end

  for {kind, audience} <- Templates.sets() do
    test "#{kind} for #{audience} renders, fits and escapes" do
      out = Renderer.render(unquote(kind), unquote(audience), content(), chrome())

      assert out.subject != ""
      assert String.length(out.subject) <= 70
      refute out.subject =~ "\n"

      assert out.html =~ "<!DOCTYPE html>"
      assert out.html =~ ~s(href="#{@url})
      assert out.html =~ "Sent by AutoQare for Evil &amp; &lt;Co&gt;"
      refute out.html =~ "<script>"
      refute out.html =~ "<b>bold</b>"
      assert out.html =~ "&lt;script&gt;"

      assert out.text =~ @url
      assert out.text =~ "Manage notifications: #{@manage}"
      assert out.text =~ "Unsubscribe from Leads: #{@unsubscribe}"
      assert out.text =~ "Sent by AutoQare for Evil & <Co>"
    end
  end

  test "a kind with no template of its own renders the fallback" do
    out = Renderer.render("tasks.removed", "staff", content(), chrome())
    assert out.html =~ "Open AutoQare"
    assert out.text =~ "Open AutoQare: #{@url}"
  end

  test "a locked kind's footer has no unsubscribe, and says why" do
    out =
      Renderer.render(
        "account.security",
        "staff",
        content(),
        %{chrome() | unsubscribe_url: nil} |> Map.put(:locked_note, "You can't turn these off.")
      )

    refute out.text =~ "Unsubscribe"
    assert out.text =~ "You can't turn these off."
  end

  test "the button is a bulletproof link, never a <button>, and the preheader is hidden" do
    out = Renderer.render("tasks.assigned", "customer", content(), chrome())
    refute out.html =~ "<button"
    assert out.html =~ ~r/<td align="center" bgcolor="#0E7C86"[^>]*>\s*<a href=/
    assert out.html =~ "display:none"
  end

  test "push words come from push.md: the title, then the body" do
    assert %{title: "Hello", body: "World"} =
             Renderer.push("tasks.assigned", "staff", %{title: "Hello", body: "World"})
  end

  doctest Renderer
end
