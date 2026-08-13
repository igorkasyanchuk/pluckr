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
      # Qualified, because `one` nodes join tables that have an `id` too, and
      # per column, because a primary key can be composite.
      keys = Array(model.primary_key).map { |key| model.arel_table[key].asc }
      ordered = relation.order_values.empty? ? order(*keys) : self

      ordered.limit(1).fetch.first
    end

    def first!
      first || raise(ActiveRecord::RecordNotFound, "Couldn't find #{model.name}")
    end

    def find(id)
      key = single_primary_key
      result = where(key => id).first
      return result if result

      raise not_found(key, id)
    end

    # See Query.for. An unloaded Relation is filtered in SQL (subquery), never
    # loaded into Ruby; a loaded one already has its records, so they are used.
    def for(records)
      key = single_primary_key

      if records.is_a?(self.class)
        raise ConfigurationError, "`for` expects #{model.name} records, not another Pluckr query; use `fetch`"
      end

      return for_relation(records, key) if records.is_a?(ActiveRecord::Relation) && !records.loaded?
      return for_many(records.to_a, key) if records.is_a?(Enumerable)

      for_one(records, key)
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

    def single_primary_key
      key = model.primary_key
      if key.is_a?(Array)
        raise ConfigurationError,
              "#{model.name} has a composite primary key; use `where(...).first` instead of `find`/`for`"
      end

      key
    end

    def for_one(record, key)
      assert_record!(record)
      find(record[key])
    end

    def for_many(records, key)
      return [] if records.empty?

      records.each { |record| assert_record!(record) }
      ids = records.map { |record| record[key] }
      index = index_by_primary_key(where(key => ids).fetch, key)

      ids.map { |id| index[id] || raise(not_found(key, id)) }
    end

    # A relation only contributes its conditions here: `select`/`order` and the
    # preloading of rows Pluckr never instantiates are dropped, and `lock` is
    # not carried into a read model. What cannot be dropped without changing
    # which rows come back has to be loaded by the caller instead.
    UNUSED_RELATION_VALUES = %i[select includes eager_load preload order lock].freeze

    def for_relation(records, key)
      unless records.klass <= model
        raise ConfigurationError,
              "`for` expects a relation for #{model.name}, got #{records.klass}"
      end

      assert_subqueryable!(records)
      scope = records.except(*UNUSED_RELATION_VALUES)
      # `offset(0)` skips nothing, but ActiveRecord still emits a LIMIT for it,
      # and MySQL cannot subquery a LIMIT at all.
      scope = scope.except(:offset) if scope.offset_value&.zero?

      where(key => scope.select(key)).fetch
    end

    # The subquery carries no ORDER BY, so `limit`/`offset` would pick arbitrary
    # rows - and MySQL rejects `IN (SELECT ... LIMIT ...)` outright. A grouped
    # relation selects the primary key it does not group by, which is not valid
    # SQL either.
    def assert_subqueryable!(records)
      reason =
        if records.limit_value || records.offset_value.to_i.positive? then "limit/offset"
        elsif records.group_values.any? then "group/having"
        end
      return unless reason

      raise ConfigurationError,
            "`for` cannot subquery a relation with #{reason}; pass the records themselves: " \
            "`for(relation.to_a)`"
    end

    def not_found(key, id)
      ActiveRecord::RecordNotFound.new(
        "Couldn't find #{model.name} with '#{key}'=#{id}", model.name, key, id
      )
    end

    def index_by_primary_key(results, key)
      output = primary_key_output(key)
      results.to_h { |row| [row[output], row] }
    end

    # Bulk `.for` reorders rows to match the input, which needs the PK on the result.
    def primary_key_output(key)
      field = query_class.pluckr_schema.fields.find { |node| node.column.to_s == key.to_s }
      return field.output if field

      raise ConfigurationError,
            "`#{query_class.name}.for` with several records needs `field :#{key}` " \
            "(or `field :#{key}, as: ...`) so results can be aligned with the input"
    end

    def assert_record!(record)
      return if record.is_a?(model)

      got = record.is_a?(ActiveRecord::Base) ? record.class.name : record.inspect
      raise ConfigurationError, "`for` expects #{model.name} records, got #{got}"
    end
  end
end
