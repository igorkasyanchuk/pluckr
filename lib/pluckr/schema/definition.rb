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

      # `first :comment, via: :comments do ... end` - the earliest row of a
      # collection, by primary key unless `order:` says otherwise.
      def first(name, via: nil, order: nil, &block)
        pick(:first, name, via: via, order: order, &block)
      end

      # `last :comment, via: :comments, order: :created_at do ... end`
      def last(name, via: nil, order: nil, &block)
        pick(:last, name, via: via, order: order, &block)
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

      def avg(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:avg, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end
      alias average avg

      def min(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:min, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end

      def max(name, from: nil, via: nil, as: nil, where: nil, column: nil, scope: nil)
        aggregate(:max, name, from: from, via: via, as: as, where: where, column: column, scope: scope)
      end

      # ------------------------------------------------------------ internals --

      private

      def pick(direction, name, via:, order:, &block)
        require_source!("#{direction} :#{name}")
        raise ConfigurationError, "`#{direction} :#{name}` requires a block" unless block

        association = Reflection::Association.for(@model, via || name)
        scope = Definition.build(association.klass, label: "#{direction} :#{name}", &block)
        validate_picked_scope!(direction, name, scope)

        add One.new(
          output: name,
          association: association,
          scope: scope,
          pick: direction,
          order: pick_order(direction, name, order, association.klass)
        )
      end

      # Every column of the picked row comes from its own subquery, so nesting
      # anything that needs a joined table cannot work here.
      def validate_picked_scope!(direction, name, scope)
        offender = scope.nodes.reject { |node| node.is_a?(Field) }.first
        return unless offender

        raise ConfigurationError,
              "`#{direction} :#{name}` can only contain `field` in v0.1, " \
              "got `#{offender.class.name.split("::").last.downcase} :#{offender.output}`"
      end

      # Normalises `order:` into [[column, direction], ...].
      #
      # `last` reverses it, so `last ..., order: { created_at: :asc }` is the
      # final row of that ordering - what `relation.order(...).last` returns. The
      # primary key always ends the list, so ties cannot make two columns come
      # from two different rows.
      def pick_order(direction, name, order, model)
        entries = Array(order_entries(direction, name, order))
        entries.each { |column, _| validate_column!(model, column) }
        entries = entries.map { |column, dir| [column, invert(dir)] } if direction == :last

        primary_key = model.primary_key&.to_sym
        tiebreaker = direction == :last ? :desc : :asc
        entries << [primary_key, tiebreaker] if primary_key && entries.none? { |column, _| column == primary_key }
        entries.freeze
      end

      def invert(direction)
        direction == :asc ? :desc : :asc
      end

      def order_entries(direction, name, order)
        case order
        when nil then []
        when Symbol, String then [[order.to_sym, :asc]]
        when Hash then order.map { |column, dir| [column.to_sym, order_direction(direction, name, dir)] }
        when Array then order.flat_map { |entry| order_entries(direction, name, entry) }
        else
          raise ConfigurationError,
                "`#{direction} :#{name}, order:` expects a column, a Hash or an Array, got #{order.inspect}"
        end
      end

      def order_direction(direction, name, value)
        normalized = value.to_s.downcase.to_sym
        return normalized if %i[asc desc].include?(normalized)

        raise ConfigurationError,
              "`#{direction} :#{name}, order:` expects :asc or :desc, got #{value.inspect}"
      end

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

      # A Hash is checked now; a callable can only be checked when it runs, on
      # every compilation.
      def validate_where!(model, where)
        return if where.nil?

        if where.respond_to?(:call)
          return if !where.respond_to?(:arity) || where.arity <= 0

          raise ConfigurationError,
                "a `where:` callable takes no arguments and returns a Hash - use `scope:` if you " \
                "need the relation"
        end

        unless where.is_a?(Hash)
          raise ConfigurationError,
                "`where:` expects a Hash of column => value or a callable returning one, " \
                "got #{where.inspect}"
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
