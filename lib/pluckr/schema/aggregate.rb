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
      include Conditions

      OPERATIONS = %i[count sum min max exists].freeze

      attr_reader :operation, :association, :model, :relation, :column, :where, :scope

      def initialize(output:, operation:, association: nil, model: nil, relation: nil,
                     column: nil, where: nil, scope: nil)
        super(output: output)
        @operation = operation.to_sym
        unless OPERATIONS.include?(@operation)
          raise ConfigurationError, "unsupported aggregate operation `#{operation}`"
        end

        @association = association
        @model = model
        @relation = relation
        @column = column&.to_sym
        @where = where.respond_to?(:call) ? where : where&.dup&.freeze
        @scope = scope
        freeze
      end

      # Independent aggregates are not rooted in the source record.
      def independent?
        !model.nil? || !relation.nil?
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
        model || relation&.klass || association.klass
      end
    end
  end
end
