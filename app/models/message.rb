class Message < ApplicationRecord
  belongs_to :conversation

  ROLES = %w[ user assistant ].freeze
  INPUT_SOURCES = %w[ text voice ].freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :content, presence: true
  validates :input_source, inclusion: { in: INPUT_SOURCES }, allow_nil: true
  validate :content_is_a_block_array

  # created_at alone ties when a turn writes two rows inside the same job, and the
  # order of those two rows is the difference between a valid request and a 400.
  scope :chronological, -> { order(:created_at, :id) }

  # Content is stored as the raw Anthropic content blocks and replayed verbatim.
  # Postgres hands them back with string keys; the SDK wants symbols. That's the
  # whole translation — nothing here reshapes a block, because a thinking block's
  # signature only validates if it goes back exactly as it came.
  def api_content
    content.map(&:deep_symbolize_keys)
  end

  def text
    blocks_of_type("text").filter_map { |block| block["text"].presence }.join("\n\n")
  end

  # Assistant turns that only called a tool have no text. They still get persisted
  # (the tool_use block has to be in the history) but there is nothing to render.
  def text?
    text.present?
  end

  def tool_results
    blocks_of_type("tool_result").map do |block|
      { payload: parse_payload(block["content"]), error: block["is_error"] == true }
    end
  end

  def tool_result?
    blocks_of_type("tool_result").any?
  end

  # An assistant turn that only called a tool has nothing to show. It is still part of
  # the history — the tool_use block has to be there — it just isn't a chat bubble.
  def renderable?
    text? || tool_result?
  end

  private
    def blocks_of_type(type)
      return [] unless content.is_a?(Array)

      content.select { |block| block.is_a?(Hash) && block["type"] == type }
    end

    def parse_payload(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      {}
    end

    def content_is_a_block_array
      return if content.is_a?(Array) && content.all? { |block| block.is_a?(Hash) }

      errors.add(:content, "must be an array of content blocks")
    end
end
