# frozen_string_literal: true

module Pluckr
  module Compiler
    # Turns a Schema::Scope into SQL.
    #
    # Everything is built with Arel and ActiveRecord, so PostgreSQL, MySQL and
    # SQLite all get correctly quoted statements from the same code path.
    #
    # Rules of the MVP:
    #   * plain fields          -> selected columns, never `SELECT users.*`
    #   * singular associations -> LEFT OUTER JOIN + hidden presence marker
    #   * exists                -> correlated EXISTS subquery
    #   * count/sum/min/max     -> scalar subquery (never JOIN + GROUP BY)
    #
    # The compiler only reads the AST. It never touches DSL state.
    class Sql
      attr_reader :schema, :source_model

      def initialize(schema:, source_model: nil)
        @schema = schema
        @source_model = source_model
      end

      # Applies Pluckr projections/joins on top of a plain ActiveRecord relation.
      #
      # Compiled fresh every time: `scope:` callables may depend on runtime state
      # and the compiler must stay free of shared mutable state.
      def apply(relation)
        build = Build.new
        walk(build, schema, [], source_model.arel_table)

        relation.select(*build.projections).joins(build.joins)
      end

      # Single-statement SQL for aggregate-only (dashboard) queries.
      def aggregate_only_sql
        parts = schema.nodes.map do |node|
          "#{scalar_subquery(node)} AS #{quote_alias(node.output)}"
        end

        "SELECT #{parts.join(", ")}"
      end

      def connection
        connection_model.connection
      end

      private

      # Accumulator for one compilation pass.
      class Build
        attr_reader :projections, :joins

        def initialize
          @projections = []
          @joins = []
          @sequence = 0
        end

        def next_sequence
          @sequence += 1
        end
      end

      def walk(build, scope, path, table)
        scope.nodes.each do |node|
          case node
          when Schema::Field
            project build, table[node.column], Aliases.output(path, node.output)
          when Schema::Exists
            project build, exists_expression(build, node, table), Aliases.output(path, node.output)
          when Schema::Aggregate
            expression =
              if node.independent?
                scalar_subquery(node)
              else
                correlated_aggregate(build, node, table)
              end
            project build, expression, Aliases.output(path, node.output)
          when Schema::One
            walk_one(build, node, path, table)
          else
            raise Error, "unsupported schema node #{node.class}"
          end
        end
      end

      def walk_one(build, node, path, owner_table)
        child_path = path + [node.output.to_s]
        association = node.association
        child_table = association.klass.arel_table.alias(Aliases.table(child_path))

        condition = association.join_condition(child_table, owner_table)
        sti = sti_condition(association.klass, child_table)
        condition = condition.and(sti) if sti

        build.joins << Arel::Nodes::OuterJoin.new(child_table, Arel::Nodes::On.new(condition))

        # Presence marker: tells "no associated row" apart from "row with NULL columns".
        project build, child_table[association.primary_key], Aliases.presence(child_path)

        walk(build, node.scope, child_path, child_table)
      end

      def project(build, expression, output_alias)
        build.projections << Arel::Nodes::As.new(expression, Arel.sql(quote_alias(output_alias)))
      end

      # EXISTS (SELECT 1 FROM photos WHERE photos.user_id = users.id)
      def exists_expression(build, node, owner_table)
        if node.relation_scoped?
          return Arel.sql("EXISTS (#{correlated_relation(node, owner_table, Arel.sql("1")).to_sql})")
        end

        table = subquery_table(build, node.association)
        subquery = Arel::SelectManager.new(table)
                   .project(Arel.sql("1"))
                   .where(node.association.join_condition(table, owner_table))
        subquery = restrict_to_sti(subquery, node.association.klass, table)

        Arel::Nodes::Exists.new(subquery.ast)
      end

      # (SELECT COUNT(*) FROM videos WHERE videos.user_id = users.id)
      def correlated_aggregate(build, node, owner_table)
        if node.relation_scoped?
          function = aggregate_function(node, node.association.klass.arel_table)
          return Arel.sql("(#{correlated_relation(node, owner_table, function).to_sql})")
        end

        table = subquery_table(build, node.association)
        subquery = Arel::SelectManager.new(table)
                   .project(aggregate_function(node, table))
                   .where(node.association.join_condition(table, owner_table))
        subquery = restrict_to_sti(subquery, node.association.klass, table)

        Arel::Nodes::Grouping.new(subquery.ast)
      end

      # (SELECT COUNT(*) FROM accounts WHERE accounts.active = TRUE)
      #
      # Conditions are delegated to ActiveRecord, so values are quoted by the
      # adapter - never string-interpolated here.
      def scalar_subquery(node)
        relation = narrow(node, node.model.all)
        relation = relation.select(aggregate_function(node, node.model.arel_table))

        Arel.sql("(#{relation.to_sql})")
      end

      # `where:`/`scope:` conditions are written against the model's real table,
      # so the correlated subquery cannot use a table alias. That is only a
      # problem when the association points back at the root table.
      def correlated_relation(node, owner_table, projection)
        klass = node.association.klass

        if klass.table_name == source_model.table_name
          raise ConfigurationError,
                "`#{node.output}`: `where:`/`scope:` are not supported on a self-referential " \
                "association (#{klass.name} and the source share table `#{klass.table_name}`)"
        end

        relation = narrow(node, klass.all)
        relation.where(node.association.join_condition(klass.arel_table, owner_table))
                .select(projection)
      end

      def narrow(node, relation)
        relation = apply_scope(node, relation)
        node.where ? relation.where(node.where) : relation
      end

      def apply_scope(node, relation)
        return relation unless node.scope

        zero_arity = node.scope.respond_to?(:arity) && node.scope.arity.zero?
        scoped = zero_arity ? node.scope.call : node.scope.call(relation)

        unless scoped.is_a?(ActiveRecord::Relation) && scoped.klass == relation.klass
          raise ConfigurationError,
                "`#{node.output}`: `scope:` must return an ActiveRecord::Relation for " \
                "#{relation.klass.name}, got #{scoped.inspect}"
        end

        scoped
      end

      def aggregate_function(node, table)
        case node.operation
        when :count
          node.column ? Arel::Nodes::Count.new([table[node.column]]) : Arel::Nodes::Count.new([Arel.star])
        when :sum then Arel::Nodes::Sum.new([table[node.column]])
        when :min then Arel::Nodes::Min.new([table[node.column]])
        when :max then Arel::Nodes::Max.new([table[node.column]])
        else
          raise Error, "unsupported aggregate operation #{node.operation}"
        end
      end

      def restrict_to_sti(subquery, klass, table)
        condition = sti_condition(klass, table)
        condition ? subquery.where(condition) : subquery
      end

      # Single table inheritance: an association to an STI child must be
      # restricted to its own types. `type_condition` accepts the aliased table,
      # which is why Pluckr uses it instead of rebuilding the condition.
      def sti_condition(klass, table)
        return nil unless klass.finder_needs_type_condition?

        klass.send(:type_condition, table)
      end

      def subquery_table(build, association)
        association.klass.arel_table.alias("#{Aliases::TABLE_PREFIX}_sub_#{build.next_sequence}")
      end

      def quote_alias(name)
        name = name.to_s
        limit = connection.max_identifier_length

        if name.bytesize > limit
          raise ConfigurationError,
                "output alias `#{name}` is #{name.bytesize} bytes, over this database's " \
                "#{limit}-byte identifier limit - shorten it with `as:`"
        end

        connection.quote_column_name(name)
      end

      def connection_model
        @connection_model ||=
          source_model ||
          schema.nodes.grep(Schema::Aggregate).map(&:target_model).first ||
          ActiveRecord::Base
      end
    end
  end
end
