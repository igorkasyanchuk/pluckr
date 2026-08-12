# frozen_string_literal: true

module Pluckr
  module Schema
    # `one :plan, via: :subscription do ... end`
    #
    # Compiles to a LEFT OUTER JOIN plus a hidden presence marker so that
    # "association missing" and "association present with NULL columns" stay
    # distinguishable.
    #
    # `first :comment, via: :comments do ... end` and its `last` counterpart use
    # the same node with `pick` and `order` set: one row out of a collection,
    # compiled as correlated subqueries instead of a join.
    class One < Node
      attr_reader :association, :scope, :pick, :order

      def initialize(output:, association:, scope:, pick: nil, order: nil)
        super(output: output)
        @association = association
        @scope = scope
        @pick = pick
        @order = order&.freeze
        freeze
      end

      # True when this node picks one row out of many rather than following a
      # singular association.
      def picked?
        !pick.nil?
      end

      def scalar?
        false
      end
    end
  end
end
