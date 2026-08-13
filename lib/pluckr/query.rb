# frozen_string_literal: true

module Pluckr
  # Subclass this to declare a read model:
  #
  #   class UserSummary < Pluckr::Query
  #     source User
  #
  #     schema do
  #       field :id
  #       field :email
  #       one :subscription do
  #         field :name
  #       end
  #       exists :photos
  #       count :videos
  #     end
  #   end
  class Query
    class << self
      # ------------------------------------------------------------- DSL --

      def source(model)
        unless model.is_a?(Class) && model < ActiveRecord::Base
          raise ConfigurationError, "`source` expects an ActiveRecord model, got #{model.inspect}"
        end

        @source_model = model
      end

      def schema(&block)
        @pluckr_schema = Schema::Definition.build(source_model, &block)
        reset_compilation!
        @pluckr_schema
      end

      # Declared on this class, or inherited from the query it subclasses.
      def source_model
        @source_model || inherited_from_query(:source_model)
      end

      def pluckr_schema
        declared_schema || raise(ConfigurationError, "#{name} has no `schema` block")
      end

      # The schema declared here or by a query this one subclasses, or nil.
      # Kept separate from `pluckr_schema` so the error names the class that was
      # actually used, not an intermediate base class.
      def declared_schema
        @pluckr_schema || inherited_from_query(:declared_schema)
      end

      # Source-rooted queries return rows; aggregate-only queries return one object.
      def source_rooted?
        !source_model.nil?
      end

      # ---------------------------------------------------------- querying --

      def all
        raise MissingSource, "#{name} has no `source` model to query" unless source_rooted?

        Relation.new(self, source_model.all)
      end

      def where(...)
        all.where(...)
      end

      def order(...)
        all.order(...)
      end

      def limit(value)
        all.limit(value)
      end

      def offset(value)
        all.offset(value)
      end

      def find(...)
        all.find(...)
      end

      def find_by(...)
        all.find_by(...)
      end

      def find_by!(...)
        all.find_by!(...)
      end

      # `COUNT(*)`/`SELECT 1` over the root rows, not a fetch counted in Ruby.
      def count(...)
        all.count(...)
      end
      alias_method :size, :count

      def exists?(...)
        all.exists?(...)
      end

      def any?(...)
        all.any?(...)
      end

      def none?(...)
        all.none?(...)
      end

      def empty?
        all.empty?
      end

      def find_each(...)
        all.find_each(...)
      end

      def in_batches(...)
        all.in_batches(...)
      end

      # Read models for records already in memory. One statement for a collection.
      #
      #   UserCard.for(user)     # one object, like find(user.id)
      #   UserCard.for(users)    # array, same order, one SQL
      #   UserCard.for(scope)    # an unloaded relation stays a subquery
      #   UserCard.for(scope.limit(2)) # a page: its keys first, then one read
      def for(records)
        all.for(records)
      end

      def first(...)
        all.first(...)
      end

      def first!
        all.first!
      end

      def last(...)
        all.last(...)
      end

      def last!
        all.last!
      end

      def take(...)
        all.take(...)
      end

      def take!
        all.take!
      end

      def one?(...)
        all.one?(...)
      end

      def many?(...)
        all.many?(...)
      end

      def fetch
        source_rooted? ? all.fetch : fetch_aggregates
      end

      def to_sql
        source_rooted? ? all.to_sql : compiler.aggregate_only_sql
      end

      def explain(...)
        all.explain(...)
      end

      # ---------------------------------------------------------- internals --

      def compiler
        @compiler ||= Compiler::Sql.new(schema: pluckr_schema, source_model: source_model)
      end

      def result_builder
        @result_builder ||= Result::Builder.new(pluckr_schema, label: name || "Pluckr::Result")
      end

      private

      def inherited_from_query(reader)
        return nil unless superclass.respond_to?(reader) && superclass <= Query && superclass != Query

        superclass.public_send(reader)
      end

      def fetch_aggregates
        row = Pluckr.select_all(compiler.connection, to_sql, name: name).first
        result_builder.build(row)
      end

      def reset_compilation!
        @compiler = nil
        @result_builder = nil
      end
    end
  end
end
