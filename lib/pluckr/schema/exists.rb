# frozen_string_literal: true

module Pluckr
  module Schema
    # `exists :photos` -> correlated `EXISTS (SELECT 1 FROM photos WHERE ...)`
    class Exists < Node
      include Conditions

      attr_reader :association, :where, :scope

      def initialize(output:, association:, where: nil, scope: nil)
        super(output: output)
        @association = association
        @where = where.respond_to?(:call) ? where : where&.dup&.freeze
        @scope = scope
        freeze
      end

      def target_model
        association.klass
      end

      def relation_scoped?
        !scope.nil? || !where.nil?
      end
    end
  end
end
