# frozen_string_literal: true

module Pluckr
  module Schema
    # Base class for every AST node.
    #
    # `output` is the key the node produces on the result object.
    class Node
      attr_reader :output

      def initialize(output:)
        @output = output.to_sym
      end

      # Nodes that map to exactly one selected column/expression.
      def scalar?
        true
      end
    end
  end
end
