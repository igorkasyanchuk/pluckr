# frozen_string_literal: true

module Pluckr
  module Schema
    # `exists :photos` -> correlated `EXISTS (SELECT 1 FROM photos WHERE ...)`
    class Exists < Node
      attr_reader :association

      def initialize(output:, association:)
        super(output: output)
        @association = association
        freeze
      end
    end
  end
end
