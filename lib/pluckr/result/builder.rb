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
        when Schema::Field then model.type_for_attribute(node.column)
        when Schema::Exists then BOOLEAN
        when Schema::Aggregate then aggregate_caster(node)
        end
      end

      def aggregate_caster(node)
        case node.operation
        when :count then INTEGER
        when :exists then BOOLEAN
        else node.target_model.type_for_attribute(node.column)
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
              cast(casters[node.output], row[Aliases.output(path, node.output)])
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

      def cast(caster, value)
        return value if value.nil? || caster.nil?

        caster.deserialize(value)
      end
    end
  end
end
