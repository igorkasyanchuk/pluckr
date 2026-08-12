# frozen_string_literal: true

module Pluckr
  module Result
    # Turns one flat database row into nested result objects.
    #
    # Result classes and per-column casters are built once per schema level when
    # the builder is created, so hydration itself is hash lookups plus a cast.
    class Builder
      BOOLEAN = ActiveModel::Type::Boolean.new
      INTEGER = ActiveModel::Type::Integer.new
      # AVG of an integer column is not an integer; ActiveRecord answers a
      # BigDecimal here and so does Pluckr.
      DECIMAL = ActiveRecord::Type::Decimal.new

      # Casts one column of a row. `default` covers SQL returning NULL where the
      # equivalent ActiveRecord call would not: SUM over no rows is NULL in SQL
      # and 0 in `relation.sum(:column)`.
      Caster = Struct.new(:type, :default) do
        def call(value)
          return default if value.nil?

          type ? type.deserialize(value) : value
        end
      end

      def initialize(schema, label: "Pluckr::Result")
        @schema = schema
        @classes = {}
        @casters = {}
        prepare(schema, label)
      end

      # @param row [Hash] flat row keyed by SQL alias
      def build(row)
        hydrate(@schema, [], row)
      end

      private

      def prepare(scope, label)
        @classes[scope] = Object.build_class(scope.outputs, label)
        @casters[scope] = scope.nodes.to_h { |node| [node.output, caster_for(node, scope.model)] }

        scope.ones.each do |node|
          prepare(node.scope, "#{label}.#{node.output}")
        end
      end

      # SQLite and MySQL hand back 1/0 where PostgreSQL hands back true/false,
      # and raw SQL carries no column type, so Pluckr casts values itself.
      def caster_for(node, model)
        case node
        when Schema::Field then Caster.new(model.type_for_attribute(node.column))
        when Schema::Exists then Caster.new(BOOLEAN)
        when Schema::Aggregate then aggregate_caster(node)
        end
      end

      def aggregate_caster(node)
        case node.operation
        when :count then Caster.new(INTEGER)
        when :exists then Caster.new(BOOLEAN)
        when :avg then Caster.new(DECIMAL) # nil for no rows, like `relation.average`
        else
          type = node.target_model.type_for_attribute(node.column)
          # `sum` answers 0 for no rows, like ActiveRecord; `min`/`max` stay nil,
          # because no row means no minimum.
          Caster.new(type, node.operation == :sum ? type.cast(0) : nil)
        end
      end

      def hydrate(scope, path, row)
        casters = @casters[scope]
        attributes = {}

        scope.nodes.each do |node|
          attributes[node.output] =
            if node.is_a?(Schema::One)
              hydrate_one(node, path, row)
            else
              casters[node.output].call(row[Aliases.output(path, node.output)])
            end
        end

        @classes[scope].new(attributes)
      end

      def hydrate_one(node, path, row)
        child_path = path + [node.output.to_s]
        # No presence marker -> no associated row at all (as opposed to a row
        # whose selected columns happen to be NULL).
        return nil if row[Aliases.presence(child_path)].nil?

        hydrate(node.scope, child_path, row)
      end

    end
  end
end
