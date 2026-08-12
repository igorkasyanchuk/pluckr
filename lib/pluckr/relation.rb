# frozen_string_literal: true

module Pluckr
  # Immutable, chainable wrapper around the root ActiveRecord relation.
  #
  # Root filtering/ordering/pagination is delegated to ActiveRecord - Pluckr
  # only adds its projections and joins when the query is compiled.
  class Relation
    include Enumerable

    attr_reader :query_class, :relation

    def initialize(query_class, relation)
      @query_class = query_class
      @relation = relation
      freeze
    end

    # `where` with no arguments returns a chain, so `where.not(...)` works like
    # it does on an ActiveRecord relation.
    def where(*args, **options, &block)
      return WhereChain.new(self) if args.empty? && options.empty? && block.nil?

      spawn(relation.where(*args, **options, &block))
    end

    def order(...)
      spawn(relation.order(...))
    end

    def limit(value)
      spawn(relation.limit(value))
    end

    def offset(value)
      spawn(relation.offset(value))
    end

    def to_sql
      query_class.compiler.apply(relation).to_sql
    end

    # One statement, one round trip, plain result objects.
    def fetch
      builder = query_class.result_builder
      rows = query_class.compiler.connection.select_all(to_sql, "#{query_class.name} Pluckr")
      rows.map { |row| builder.build(row) }
    end
    alias to_a fetch

    def each(&block)
      fetch.each(&block)
    end

    # ActiveRecord orders by primary key when the relation has no order of its
    # own, so that `first` means something. Same here.
    def first
      # Qualified, because `one` nodes join tables that have an `id` too.
      ordered = relation.order_values.empty? ? order(model.arel_table[model.primary_key].asc) : self

      ordered.limit(1).fetch.first
    end

    def first!
      first || raise(ActiveRecord::RecordNotFound, "Couldn't find #{model.name}")
    end

    def find(id)
      key = model.primary_key
      result = where(key => id).first
      return result if result

      raise ActiveRecord::RecordNotFound.new(
        "Couldn't find #{model.name} with '#{key}'=#{id}", model.name, key, id
      )
    end

    def inspect
      "#<Pluckr::Relation #{query_class.name} #{to_sql}>"
    end

    def spawn(new_relation)
      self.class.new(query_class, new_relation)
    end

    # Mirrors ActiveRecord::QueryMethods::WhereChain for the operations Pluckr
    # supports on the root relation.
    class WhereChain
      def initialize(pluckr_relation)
        @pluckr_relation = pluckr_relation
      end

      def not(...)
        @pluckr_relation.spawn(@pluckr_relation.relation.where.not(...))
      end
    end

    private

    def model
      query_class.source_model
    end
  end
end
