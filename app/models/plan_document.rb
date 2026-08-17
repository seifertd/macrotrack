# Renders doc/IMPLEMENTATION-PLAN.md as HTML for the /plan page.
#
# Reads the markdown out of the deployed release rather than a build artifact,
# so the page can never drift from the code it describes. Cached on the file's
# mtime, which means a deploy invalidates it and nothing else has to.
class PlanDocument
  SOURCE = Rails.root.join("doc", "IMPLEMENTATION-PLAN.md")

  CHIPS = { "done" => "Done", "next" => "Next up", "later" => "Planned" }.freeze

  # One work package: enough to build a nav entry that links into the body.
  Package = Struct.new(:anchor, :number, :title, :state, keyword_init: true) do
    def label = "WP#{number}"
    def chip = CHIPS[state]
  end

  class << self
    # => [html, packages]
    def render
      Rails.cache.fetch("plan_document/#{SOURCE.mtime.to_i}") { new.render }
    end

    def exists? = SOURCE.exist?
    def updated_at = SOURCE.mtime
  end

  def initialize
    @packages = []
  end

  def render
    html = markdown.render(source_without_title)
    html = annotate_headings(html)
    [ scroll_wrap_tables(html).html_safe, @packages ]
  end

  private
    def source_without_title
      SOURCE.read.sub(/\A# .*?\n/, "")
    end

    def markdown
      Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new,
        tables: true, fenced_code_blocks: true, autolink: true,
        strikethrough: true, no_intra_emphasis: true
      )
    end

    # Gives each work package a stable anchor and a status chip, and collects them
    # for the nav. Only work packages are annotated — the reference sections
    # above them aren't scheduled work, so a chip there would be decoration.
    def annotate_headings(html)
      html.gsub(%r{<h2>(.*?)</h2>}m) do
        inner = $1
        text = inner.sub("✅", "").gsub(/\s+/, " ").strip

        match = text.match(/\AWP([\d.]+)\s+—\s+(.*)\z/m)
        next %(<h2>#{text}</h2>) unless match

        number, rest = match[1], match[2]
        state = state_for(inner, number)
        anchor = "wp#{number.tr('.', '-')}"

        @packages << Package.new(anchor:, number:, title: plain_title(rest), state:)

        chip = %(<span class="chip chip--#{state}">#{CHIPS[state]}</span>)
        %(<h2 id="#{anchor}" class="wp">#{chip}<span class="wp__text">#{text}</span></h2>)
      end
    end

    def state_for(inner, number)
      return "done" if inner.include?("✅")
      number == "4" ? "next" : "later"
    end

    # The heading carries a parenthetical target, a completion date and stray
    # markup; the nav wants just the name. Entities are decoded because ERB
    # escapes the value again on the way out.
    def plain_title(rest)
      CGI.unescapeHTML(rest.gsub(%r{<[^>]+>}, ""))
        .sub(/\s*\(target:.*\z/m, "")
        .sub(/\s*—\s*built here.*\z/im, "")
        .sub(/\s*done\s+\d{4}-\d{2}-\d{2}\s*\z/i, "")
        .strip
    end

    # Wide tables scroll inside their own container so the page body never does.
    def scroll_wrap_tables(html)
      html.gsub("<table>", %(<div class="scroller"><table>)).gsub("</table>", "</table></div>")
    end
end
