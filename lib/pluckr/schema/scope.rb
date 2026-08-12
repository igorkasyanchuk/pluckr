# frozen_string_literal: true

module Pluckr
  module Schema
    # A level of the AST: the nodes selected for one model (the root source, or
    # one nested singular association).
    class Scope
      attr_reader :model, :nodes

      def initialize(model, nodes)
        @model = model
        @nodes = nodes.freeze
        freeze
      end

      def fields
        nodes.grep(Field)
      end

      def ones
        nodes.grep(One)
      end

      def outputs
        nodes.map(&:output)
      end

      # True when anything here needs a root record to hang off.
      def rooted?
        nodes.any? { |node| !(node.is_a?(Aggregate) && node.independent?) }
      end
    end
  end
end
