# frozen_string_literal: true

module Pluckr
  module Schema
    # `exists :photos` -> correlated `EXISTS (SELECT 1 FROM photos WHERE ...)`
    class Exists < Node
      attr_reader :association, :where, :scope

      def initialize(output:, association:, where: nil, scope: nil)
        super(output: output)
        @association = association
        @where = where ? where.dup.freeze : nil
        @scope = scope
        freeze
      end

      def relation_scoped?
        !scope.nil? || !where.nil?
      end
    end
  end
end
