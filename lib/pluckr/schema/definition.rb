# frozen_string_literal: true

module Pluckr
  module Schema
    # Evaluates the `schema do ... end` block and builds a Scope of AST nodes.
    #
    # All validation happens here, at class-definition time, so mistakes blow up
    # when the query is loaded rather than when it is executed.
    class Definition
      # @param model [Class<ActiveRecord::Base>, nil] nil for aggregate-only queries
      def self.build(model, label: "schema", &block)
        raise ConfigurationError, "`#{label}` requires a block" unless block

        definition = new(model)
        definition.instance_eval(&block)
        scope = definition.to_scope

        raise ConfigurationError, "`#{label}` block is empty - declare at least one node" if scope.nodes.empty?

        scope
      end

      def initialize(model)
        @model = model
        @nodes = []
      end

      def to_scope
        Scope.new(@model, @nodes)
      end

      # ---------------------------------------------------------------- DSL --

      def field(name, as: nil)
        require_source!("field :#{name}")
        validate_column!(@model, name)
        add Field.new(column: name, output: as || name)
      end

      def one(name, via: nil, &block)
        require_source!("one :#{name}")
        raise ConfigurationError, "`one :#{name}` requires a block" unless block

        association = Reflection::Association.for(@model, via || name)
        unless association.singular?
          raise InvalidAssociation,
                "`#{@model.name}##{association.name}` is a #{association.macro} association " \
                "and cannot be used with `one`"
        end

        add One.new(
          output: name,
          association: association,
          scope: Definition.build(association.klass, label: "one :#{name}", &block)
        )
      end

      def exists(name, via: nil, as: nil, where: nil, scope: nil)
        require_source!("exists :#{name}")
        association = Reflection::Association.for(@model, via || name)
        validate_where!(association.klass, where)
        validate_scope!("exists :#{name}", scope)

        add Exists.new(
          output: as || :"#{name}_exists",
          association: association,
          where: where,
          scope: scope
        )
      end

      def count(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:count, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end

      def sum(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:sum, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end

      def min(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:min, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end

      def max(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:max, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end

      # ------------------------------------------------------------ internals --

      private

      def aggregate(operation, name, from:, via:, as:, where:, column:, scope:)
        validate_scope!("#{operation} :#{name}", scope)

        if from
          independent_aggregate(operation, name, from: from, as: as, where: where,
                                                 column: column, scope: scope)
        else
          correlated_aggregate(operation, name, via: via, as: as, where: where,
                                                column: column, scope: scope)
        end
      end

      def independent_aggregate(operation, name, from:, as:, where:, column:, scope:)
        unless from.is_a?(Class) && from < ActiveRecord::Base
          raise ConfigurationError,
                "`#{operation} :#{name}, from:` expects an ActiveRecord model, got #{from.inspect}"
        end

        column = require_column!(operation, name, column, from)
        validate_where!(from, where)

        add Aggregate.new(
          output: as || name,
          operation: operation,
          model: from,
          column: column,
          where: where,
          scope: scope
        )
      end

      def correlated_aggregate(operation, name, via:, as:, where:, column:, scope:)
        require_source!("#{operation} :#{name}")

        association = Reflection::Association.for(@model, via || name)
        column = require_column!(operation, name, column, association.klass)
        validate_where!(association.klass, where)

        add Aggregate.new(
          output: as || :"#{name}_#{operation}",
          operation: operation,
          association: association,
          column: column,
          where: where,
          scope: scope
        )
      end

      # count is the only operation that works without a column (COUNT(*)).
      def require_column!(operation, name, column, model)
        if column.nil?
          return nil if operation == :count

          raise ConfigurationError, "`#{operation} :#{name}` requires `column:`"
        end

        validate_column!(model, column)
        column
      end

      def validate_column!(model, name)
        return if model.column_names.include?(name.to_s)

        raise UnknownField, "#{model.name} does not have column `#{name}`"
      end

      def validate_where!(model, where)
        return if where.nil?

        unless where.is_a?(Hash)
          raise ConfigurationError, "`where:` expects a Hash of column => value, got #{where.inspect}"
        end

        where.each_key { |key| validate_column!(model, key) }
      end

      # `scope:` takes the target model's relation and returns a narrowed one:
      #   count :active_accounts, from: Account, scope: ->(rel) { rel.active }
      def validate_scope!(node, scope)
        return if scope.nil? || scope.respond_to?(:call)

        raise ConfigurationError, "`#{node}, scope:` expects a callable, got #{scope.inspect}"
      end

      def require_source!(node)
        return unless @model.nil?

        raise MissingSource, "`#{node}` needs a root record - declare `source SomeModel` on the query"
      end

      def add(node)
        if @nodes.any? { |existing| existing.output == node.output }
          raise ConfigurationError, "duplicate output name `#{node.output}` in schema"
        end

        @nodes << node
        node
      end
    end
  end
end
