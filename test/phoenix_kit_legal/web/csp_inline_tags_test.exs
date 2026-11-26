defmodule PhoenixKit.Modules.Legal.Web.CSPInlineTagsTest do
  @moduledoc """
  What this module renders has to pass a host's nonce Content-Security-Policy
  (`script-src 'self' 'nonce-…'`): every inline `<script>` / `<style>` in `lib/` carries the
  nonce (`PhoenixKit.Modules.Legal.Web.CSP.nonce/1`), nothing carries an inline event handler
  (no nonce covers an attribute), and a `<style>` the banner script creates is stamped before
  it joins the document. Modelled on core's `PhoenixKitWeb.CSPInlineTagsTest`.

  No exemptions: the module renders no cached document and no e-mail. The generated legal
  pages (`priv/legal_templates/*.eex`) are Markdown handed to Publishing, checked below for
  tags and handlers all the same.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Modules.Legal.CookieConsent
  alias PhoenixKit.Modules.Legal.Web.CSP

  @script "priv/static/assets/phoenix_kit_consent.js"
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s
  @tag_opening ~r/<(script|style)\b[^>]*>/s

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave
             touchstart touchend touchmove pointerdown pointerup pointermove
             dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no inline <script> or <style> in lib/ or the page templates is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}") ++ Path.wildcard("priv/**/*.eex"),
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={CSP.nonce(kind)}` " <>
             "(PhoenixKit.Modules.Legal.Web.CSP):\n" <> Enum.join(offenders, "\n")
  end

  test "the scan sees the widget's <style>" do
    assert [{opening, _line}] = tag_openings("lib/phoenix_kit_legal/web/cookie_consent.ex")
    assert opening =~ "<style" and opening =~ "CSP.nonce(:style)"
  end

  test "no markup in lib/ or the page templates carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}") ++ Path.wildcard("priv/**/*.eex"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; name the action with `data-pkl-consent` " <>
             "or use a `phx-` binding):\n" <> Enum.join(offenders, "\n")
  end

  test "the banner script builds no markup with an inline event handler" do
    offenders =
      for {line, number} <- script_lines(),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/javascript:/i,
          do: "#{@script}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # `innerHTML` cannot give a <style> a nonce, so one written as a string is dropped by the
  # policy; an element is stamped (`adoptStyle`) before it has any text.
  test "every <style> the banner script creates is stamped, and none is written as a string" do
    lines = script_lines()

    offenders =
      for {line, number} <- lines,
          next = Enum.filter(lines, fn {_, n} -> n > number and n <= number + 4 end),
          problem = style_problem(line, next),
          do: "#{@script}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
    assert Enum.any?(lines, fn {line, _} -> line =~ ~r/createElement\(["']style["']\)/ end)
  end

  test "a script the banner releases is given the nonce of the tag it replaces" do
    source = File.read!(@script)
    assert source =~ "if (script.nonce) newScript.nonce = script.nonce;"
    assert source =~ ~s(attr.name !== "nonce")
  end

  describe "CSP.nonce/1" do
    test "is nil when the host set no nonce, so no attribute is rendered" do
      assert CSP.nonce(:style) == nil
      assert CSP.nonce(:script) == nil
    end

    # Only a core that has `PhoenixKitWeb.CSP` can hand one over; on an older core this module
    # must keep compiling and answering nil (the test above).
    if Code.ensure_loaded?(PhoenixKitWeb.CSP) and
         function_exported?(PhoenixKitWeb.CSP, :put_nonces, 1) do
      test "is the nonce core read from the request" do
        previous = Application.get_env(:phoenix_kit, :csp_nonce_assign_key)
        Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:phoenix_kit, :csp_nonce_assign_key, previous),
            else: Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)
        end)

        conn = Plug.Conn.assign(Plug.Test.conn(:get, "/"), :csp_nonce, "n0nce")
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PhoenixKitWeb.CSP, :put_nonces, [conn])

        assert CSP.nonce(:style) == "n0nce"
        assert CSP.nonce(:script) == "n0nce"

        html =
          render_component(
            &CookieConsent.cookie_consent/1,
            frameworks: ["gdpr"],
            consent_mode: "strict"
          )

        assert html =~ ~s(<style nonce="n0nce">)
      end
    end
  end

  defp style_problem(line, next_lines) do
    cond do
      line =~ ~r/createElement\(["']style["']\)/ and
          not Enum.any?(next_lines, fn {next, _} -> next =~ ~r/adoptStyle\(/ end) ->
        "creates a <style> that is not stamped in the next lines"

      line =~ ~r/["'`]<style\b/ ->
        "builds a <style> tag as a string"

      true ->
        nil
    end
  end

  # The script's lines, comment lines left out.
  defp script_lines do
    @script
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> line =~ ~r{^\s*(//|/?\*)} end)
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in documentation is an
  # example, not markup.
  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
