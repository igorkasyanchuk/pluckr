# frozen_string_literal: true

module Pluckr
  module Schema
    # `field :email, as: :contact_email`
    class Field < Node
      attr_reader :column

      def initialize(column:, output:)
        super(output: output)
        @column = column.to_sym
        freeze
      end
    end
  end
end
