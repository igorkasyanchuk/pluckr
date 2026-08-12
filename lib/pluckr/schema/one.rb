# frozen_string_literal: true

module Pluckr
  module Schema
    # `one :plan, via: :subscription do ... end`
    #
    # Compiles to a LEFT OUTER JOIN plus a hidden presence marker so that
    # "association missing" and "association present with NULL columns" stay
    # distinguishable.
    class One < Node
      attr_reader :association, :scope

      def initialize(output:, association:, scope:)
        super(output: output)
        @association = association
        @scope = scope
        freeze
      end

      def scalar?
        false
      end
    end
  end
end
