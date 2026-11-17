defmodule Notifire.Emails.GalleryTest do
  @moduledoc "`/dev/emails` (AQ-10B §7.3): every template with sample data, no database."

  use ExUnit.Case, async: true

  alias Notifire.Emails.{Gallery, Templates}

  test "the index links every template × audience in HTML and plain text, and the no-login ones" do
    page = Gallery.index("/dev/emails")

    for {kind, audience} <- Templates.sets() do
      assert page =~ "/dev/emails/#{kind}?audience=#{audience}&amp;format=html"
      assert page =~ "/dev/emails/#{kind}?audience=#{audience}&amp;format=text"
    end

    assert page =~ "meetings.scheduled?audience=customer&amp;format=html&amp;no_login=1"
  end

  test "every template renders with sample data; an unknown one is nil" do
    for {kind, audience} <- Templates.sets() do
      out = Gallery.render(kind, audience)
      assert out.html =~ "Sent by AutoQare for Northwind Talent"
      assert out.text =~ "Why you got this:"
    end

    assert Gallery.render("meetings.scheduled", "customer", true).text =~
             "Ask your team for a portal invitation"

    assert Gallery.render("nope.kind", "staff") == nil
  end
end
