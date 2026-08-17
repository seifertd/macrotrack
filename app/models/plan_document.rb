# Renders doc/IMPLEMENTATION-PLAN.md as HTML for the /plan page.
#
# Reads the markdown out of the deployed release rather than a build artifact,
# so the page can never drift from the code it describes. Cached on the file's
# mtime, which means a deploy invalidates it and nothing else has to.
class PlanDocument
  SOURCE = Rails.root.join("doc", "IMPLEMENTATION-PLAN.md")

  CHIPS = { "done" => "Done", "next" => "Next up", "later" => "Planned" }.freeze

  class << self
    def body_html
      Rails.cache.fetch(cache_key) { new.render }
    end

    def exists? = SOURCE.exist?

    private
      def cache_key
        "plan_document/#{SOURCE.mtime.to_i}"
      end
  end

  def render
    html = markdown.render(source_without_title)
    html = add_status_chips(html)
    scroll_wrap_tables(html).html_safe
  end

  private
    def source_without_title
      SOURCE.read.sub(/\A# .*?\n/, "")
    end

    def markdown
      Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new(with_toc_data: true),
        tables: true, fenced_code_blocks: true, autolink: true,
        strikethrough: true, no_intra_emphasis: true
      )
    end

    # Only work packages get a chip. The reference sections above them aren't
    # scheduled work, so a chip there would be decoration rather than status.
    def add_status_chips(html)
      html.gsub(%r{<h2([^>]*)>(.*?)</h2>}m) do
        attrs, inner = $1, $2
        text = inner.sub("✅", "").gsub(/\s+/, " ").strip

        next %(<h2#{attrs}>#{text}</h2>) unless text.match?(/\AWP[\d.]+ /)

        state =
          if inner.include?("✅")
            "done"
          elsif text.start_with?("WP4 —")
            "next"
          else
            "later"
          end

        chip = %(<span class="chip chip--#{state}">#{CHIPS[state]}</span>)
        %(<h2#{attrs} class="wp">#{chip}<span class="wp__text">#{text}</span></h2>)
      end
    end

    # Wide tables scroll inside their own container so the page body never does.
    def scroll_wrap_tables(html)
      html.gsub("<table>", %(<div class="scroller"><table>)).gsub("</table>", "</table></div>")
    end
end
