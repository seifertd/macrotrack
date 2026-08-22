# Renders doc/IMPLEMENTATION-PLAN.md as HTML for the /plan page.
#
# Reads the markdown out of the deployed release rather than a build artifact,
# so the page can never drift from the code it describes. Cached on the file's
# mtime, which means a deploy invalidates it and nothing else has to.
class PlanDocument
  SOURCE = Rails.root.join("doc", "IMPLEMENTATION-PLAN.md")

  CHIPS = { "done" => "Done", "next" => "Next up", "later" => "Planned" }.freeze

  # The document declares its own sequence in one line near the top. Reading it beats
  # inferring order from where sections happen to sit: packages get reordered in the
  # prose (WP6 sits above WP4 because it was promoted, then demoted again) and the
  # heading order stopped matching the build order the first time that happened.
  BUILD_ORDER = /^\*\*Build order:\*\*\s*(.+)$/
  # The optional hyphen is for WP4.5-a / WP4.5-b. Without it the number matches as
  # "4.5" and then the heading fails on the em dash that is supposed to follow, so the
  # package silently drops out of the nav rather than rendering wrong.
  PACKAGE_NUMBER = /\d+(?:\.\d+)?(?:-?[ab])?/
  HEADING = /^(\#{2,3})\s+WP(#{PACKAGE_NUMBER})\s+—\s+(.*)$/
  SUB_PACKAGE = /\A(\d+)[ab]\z/

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
    @source = SOURCE.read
    @packages = []
  end

  def render
    html = markdown.render(source_without_title)
    html = annotate_headings(html)
    [ scroll_wrap_tables(html).html_safe, ordered_packages ]
  end

  private
    def source_without_title
      @source.sub(/\A# .*?\n/, "")
    end

    def markdown
      Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new,
        tables: true, fenced_code_blocks: true, autolink: true,
        strikethrough: true, no_intra_emphasis: true
      )
    end

    # Every WP heading in the document, at either level, with whether it's finished.
    # Read from the markdown rather than the rendered HTML because this has to be known
    # before any heading is rewritten — "next up" depends on all the others.
    def headings
      @headings ||= @source.scan(HEADING).map do |hashes, number, rest|
        { number: number, level: hashes.length, done: rest.include?("✅") }
      end
    end

    # WP6 is a container for WP6a and WP6b. It is not itself a package — the build
    # order lists the halves, never the whole — and treating it as one is what made a
    # half-finished WP6 claim to be the work in progress while WP4, finished and sitting
    # below it in the document, was still being counted as ahead of it.
    #
    # Matched on a single-letter suffix so WP4 doesn't become the container of WP4.5.
    def containers
      @containers ||= headings.filter_map { |heading| heading[:number][SUB_PACKAGE, 1] }.uniq
    end

    def build_order
      @build_order ||= @source[BUILD_ORDER, 1].to_s.scan(/WP(#{PACKAGE_NUMBER})/o).flatten
    end

    # The first package the build order calls for that isn't finished. A package named
    # in the order but not yet written up is skipped rather than claiming the slot.
    def next_number
      return @next_number if defined?(@next_number)

      @next_number = build_order.find do |number|
        heading = headings.find { |candidate| candidate[:number] == number }
        heading && !heading[:done]
      end
    end

    def state_for(number, done)
      return "done" if done
      return "next" if number == next_number

      "later"
    end

    # Gives each work package a stable anchor and a status chip, and collects them for
    # the nav. Headings that aren't work packages are left exactly as they were.
    def annotate_headings(html)
      html.gsub(%r{<(h2|h3)>(.*?)</\1>}m) do |whole|
        tag, inner = Regexp.last_match(1), Regexp.last_match(2)
        text = inner.sub("✅", "").gsub(/\s+/, " ").strip
        match = text.match(/\AWP(#{PACKAGE_NUMBER})\s+—\s+(.*)\z/om)

        next whole unless match

        number, rest = match[1], match[2]
        # 4.5-a would otherwise anchor as "wp4-5--a". Squeezing is a no-op for every
        # other number, so existing anchors keep working.
        anchor = "wp#{number.tr('.', '-').squeeze('-')}"

        next %(<#{tag} id="#{anchor}" class="wp wp--group">#{text}</#{tag}>) if containers.include?(number)

        state = state_for(number, inner.include?("✅"))
        @packages << Package.new(anchor: anchor, number: number, title: plain_title(rest), state: state)

        chip = %(<span class="chip chip--#{state}">#{CHIPS[state]}</span>)
        %(<#{tag} id="#{anchor}" class="wp">#{chip}<span class="wp__text">#{text}</span></#{tag}>)
      end
    end

    # Build order first; anything the order doesn't mention (WP11 is conditional) keeps
    # its document position at the end rather than disappearing from the nav.
    def ordered_packages
      position = build_order.each_with_index.to_h

      @packages.each_with_index.sort_by { |package, index|
        [ position.fetch(package.number, build_order.size), index ]
      }.map(&:first)
    end

    # The heading carries a parenthetical aside, a completion date and stray markup;
    # the nav wants just the name. Sub-package headings start lowercase in the prose
    # ("WP6a — pick and portion"), which reads wrong in a list of proper titles.
    # Entities are decoded because ERB escapes the value again on the way out.
    def plain_title(rest)
      CGI.unescapeHTML(rest.gsub(%r{<[^>]+>}, ""))
        .sub(/\s*—\s*built here.*\z/im, "")
        .sub(/\s*done\s+\d{4}-\d{2}-\d{2}\s*\z/i, "")
        .sub(/\s*\([^()]*\)\s*\z/, "")
        .strip
        .upcase_first
    end

    # Wide tables scroll inside their own container so the page body never does.
    def scroll_wrap_tables(html)
      html.gsub("<table>", %(<div class="scroller"><table>)).gsub("</table>", "</table></div>")
    end
end
