# frozen_string_literal: true

module Pluckr
  module Schema
    # Two flavours share this node:
    #
    #   count :videos                      # correlated: association is set
    #   count :users, from: User           # independent: model is set
    #
    # Both compile to a scalar subquery in the SELECT list, never to a JOIN +
    # GROUP BY, so root rows are never multiplied.
    class Aggregate < Node
      OPERATIONS = %i[count sum min max].freeze

      attr_reader :operation, :association, :model, :column, :where, :scope

      def initialize(output:, operation:, association: nil, model: nil, column: nil, where: nil, scope: nil)
        super(output: output)
        @operation = operation.to_sym
        @association = association
        @model = model
        @column = column&.to_sym
        @where = where ? where.dup.freeze : nil
        @scope = scope
        freeze
      end

      # Independent aggregates are not rooted in the source record.
      def independent?
        !model.nil?
      end

      def correlated?
        !association.nil?
      end

      # True when the subquery must be built from an ActiveRecord relation
      # rather than straight Arel.
      def relation_scoped?
        !scope.nil? || !where.nil?
      end

      # Target model for column validation / table resolution.
      def target_model
        model || association.klass
      end
    end
  end
end
