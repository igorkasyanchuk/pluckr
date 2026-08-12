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
      def apply(relation)
        compile!
        relation.select(*@projections).joins(@joins)
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

      def compile!
        return if @projections

        @projections = []
        @joins = []
        @subquery_seq = 0
        walk(schema, [], source_model.arel_table)
      end

      def walk(scope, path, table)
        scope.nodes.each do |node|
          case node
          when Schema::Field
            project table[node.column], Aliases.output(path, node.output)
          when Schema::Exists
            project exists_expression(node, table), Aliases.output(path, node.output)
          when Schema::Aggregate
            expression = node.independent? ? scalar_subquery(node) : correlated_aggregate(node, table)
            project expression, Aliases.output(path, node.output)
          when Schema::One
            walk_one(node, path, table)
          else
            raise Error, "unsupported schema node #{node.class}"
          end
        end
      end

      def walk_one(node, path, owner_table)
        child_path = path + [node.output.to_s]
        association = node.association
        child_table = association.klass.arel_table.alias(Aliases.table(child_path))

        condition = association.join_condition(child_table, owner_table)
        sti = sti_condition(association.klass, child_table)
        condition = condition.and(sti) if sti

        @joins << Arel::Nodes::OuterJoin.new(child_table, Arel::Nodes::On.new(condition))

        # Presence marker: tells "no associated row" apart from "row with NULL columns".
        project child_table[association.primary_key], Aliases.presence(child_path)

        walk(node.scope, child_path, child_table)
      end

      def project(expression, output_alias)
        @projections << Arel::Nodes::As.new(expression, Arel.sql(quote_alias(output_alias)))
      end

      # EXISTS (SELECT 1 FROM photos WHERE photos.user_id = users.id)
      def exists_expression(node, owner_table)
        table = subquery_table(node.association)
        subquery = Arel::SelectManager.new(table)
                   .project(Arel.sql("1"))
                   .where(node.association.join_condition(table, owner_table))
        subquery = restrict_to_sti(subquery, node.association.klass, table)

        Arel::Nodes::Exists.new(subquery.ast)
      end

      # (SELECT COUNT(*) FROM videos WHERE videos.user_id = users.id)
      def correlated_aggregate(node, owner_table)
        table = subquery_table(node.association)
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
        relation = node.model.all
        relation = relation.where(node.where) if node.where
        relation = relation.select(aggregate_function(node, node.model.arel_table))

        Arel.sql("(#{relation.to_sql})")
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

      def subquery_table(association)
        @subquery_seq += 1
        association.klass.arel_table.alias("#{Aliases::TABLE_PREFIX}_sub_#{@subquery_seq}")
      end

      def quote_alias(name)
        connection.quote_column_name(name.to_s)
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
