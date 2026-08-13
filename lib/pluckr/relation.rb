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
      rows = Pluckr.select_all(query_class.compiler.connection, to_sql, name: query_class.name)
      rows.map { |row| builder.build(row) }
    end
    alias to_a fetch

    def each(&block)
      fetch.each(&block)
    end

    # Enumerable would answer these by building every result object first, which
    # is the opposite of the point. They are questions about the root rows, so
    # ActiveRecord answers them with `COUNT(*)`/`SELECT 1`, without Pluckr's
    # projections.
    # A block (or an Enumerable pattern) is a question about the results, so it
    # goes back to Enumerable - exactly where ActiveRecord sends it.
    def count(*args)
      return super if block_given?

      relation.count(*args)
    end
    alias size count

    def exists?(...)
      relation.exists?(...)
    end

    def any?(*args)
      return super if args.any? || block_given?

      exists?
    end

    def none?(*args)
      return super if args.any? || block_given?

      !exists?
    end

    def empty?
      !exists?
    end

    def explain(...)
      query_class.compiler.apply(relation).explain(...)
    end

    # ActiveRecord orders by primary key when the relation has no order of its
    # own, so that `first` means something. Same here.
    def first(limit = nil)
      results = ordered_by_primary_key.limit(within_limit(limit || 1)).fetch

      limit ? results : results.first
    end

    def first!
      first || raise(ActiveRecord::RecordNotFound, "Couldn't find #{model.name}")
    end

    # The other end of the same order, read in one `LIMIT` rather than by
    # hydrating the chain and dropping all but the tail. A chain that already
    # pages is the exception ActiveRecord makes too: its own `limit` cannot be
    # replaced by ours, so the page is read and the tail taken from it.
    def last(limit = nil)
      return last_of_page(limit) if paginated?(relation)

      results = spawn(ordered_by_primary_key.relation.reverse_order).limit(limit || 1).fetch

      limit ? results.reverse : results.first
    end

    def last!
      last || raise(ActiveRecord::RecordNotFound, "Couldn't find #{model.name}")
    end

    # Enumerable's `take` would read the whole chain to keep the front of it.
    def take(limit = nil)
      results = self.limit(limit || 1).fetch

      limit ? results : results.first
    end

    def take!
      take || raise(ActiveRecord::RecordNotFound, "Couldn't find #{model.name}")
    end

    # Two rows is all it takes to answer either question - unless the chain
    # already limits itself to fewer, in which case that limit is the answer.
    def one?(*args)
      return super if args.any? || block_given?

      limited_count == 1
    end

    def many?(*args)
      return super if args.any? || block_given?

      limited_count > 1
    end

    # `find` is the primary key lookup; a block is Enumerable's `find`, which is
    # where ActiveRecord sends it too. Several ids (or an array of them) come
    # back as an array, in the order they were asked for.
    def find(*args, &block)
      return super if block
      raise ArgumentError, "wrong number of arguments (given 0, expected 1+)" if args.empty?

      key = single_primary_key
      ids = args.size == 1 ? args.first : args
      return for_ids(ids, key) if ids.is_a?(Array)
      raise ActiveRecord::RecordNotFound, "Couldn't find #{model.name} without an ID" if ids.nil?

      where(key => ids).first || raise(not_found(key, ids))
    end

    # The arity is ActiveRecord's: at least one condition, or `ArgumentError`.
    def find_by(arg, *args)
      where(arg, *args).first
    end

    def find_by!(arg, *args)
      find_by(arg, *args) ||
        raise(ActiveRecord::RecordNotFound,
              "Couldn't find #{model.name} with #{[arg, *args].map(&:inspect).join(", ")}")
    end

    # Reads the whole chain in pages, so an export does not build every result
    # object at once. Like ActiveRecord's, the batches are ordered by primary
    # key and any order of your own is ignored - unlike ActiveRecord's, the page
    # after the first is a keyset seek (`id > last`), never an OFFSET.
    def find_each(batch_size: 1_000, &block)
      assert_batchable!(batch_size)
      return to_enum(:find_each, batch_size: batch_size) unless block_given?

      in_batches(of: batch_size) { |results| results.each(&block) }
    end

    def in_batches(of: 1_000)
      assert_batchable!(of)
      return to_enum(:in_batches, of: of) unless block_given?

      key = single_primary_key
      output = primary_key_output(key)
      scope = spawn(relation.reorder(key => :asc))
      cursor = nil

      loop do
        page = cursor ? scope.where(model.arel_table[key].gt(cursor)) : scope
        results = page.limit(of).fetch
        break if results.empty?

        yield results
        break if results.size < of

        cursor = results.last.public_send(output)
      end
    end

    # See Query.for. An unloaded Relation is filtered in SQL (subquery), never
    # loaded into Ruby; a loaded one already has its records, so they are used.
    # A paginated one is resolved to primary keys first - see
    # for_paginated_relation.
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

    # Reading the front of a page cannot reach past its end, the way
    # ActiveRecord's `find_nth_with_limit` clamps.
    def within_limit(wanted)
      relation.limit_value ? [relation.limit_value, wanted].min : wanted
    end

    # Both mirror ActiveRecord: a `limit` of the caller's own is never widened
    # to make an answer easier to reach.
    def limited_count
      relation.limit_value ? relation.count : relation.limit(2).count
    end

    def last_of_page(limit)
      results = ordered_by_primary_key.fetch

      limit ? results.last(limit) : results.last
    end

    # Qualified, because `one` nodes join tables that have an `id` too, and per
    # column, because a primary key can be composite.
    def ordered_by_primary_key
      return self unless relation.order_values.empty?

      order(*Array(model.primary_key).map { |key| model.arel_table[key].asc })
    end

    def single_primary_key
      key = model.primary_key
      if key.is_a?(Array)
        raise ConfigurationError,
              "#{model.name} has a composite primary key, which Pluckr cannot look a row up by; " \
              "use `where(...)` with `fetch`/`first` instead"
      end

      key
    end

    def for_one(record, key)
      assert_record!(record)
      find(record[key])
    end

    def for_many(records, key)
      records.each { |record| assert_record!(record) }
      for_ids(records.map { |record| record[key] }, key)
    end

    # Records the caller handed over must all come back - a missing one is a
    # deleted record, and silence would hide it. A relation is a set of
    # conditions instead, so rows the query itself filters out are simply not
    # part of the answer, exactly as they are not for an unpaginated one.
    def for_ids(ids, key, strict: true)
      return [] if ids.empty?

      index = index_by_primary_key(where(key => ids).fetch, key)
      return ids.filter_map { |id| index[id] } unless strict

      ids.map { |id| index[id] || raise(not_found(key, id)) }
    end

    # A relation only contributes its conditions here: `select`/`order` and the
    # preloading of rows Pluckr never instantiates are dropped, and `lock` is
    # not carried into a read model. What cannot be dropped without changing
    # which rows come back has to be loaded by the caller instead.
    UNUSED_RELATION_VALUES = %i[select includes eager_load preload order lock].freeze

    # A paginated relation keeps its order, so it cannot lose it to a subquery -
    # nor to the joins that order may depend on. Only the projection and the
    # lock go; `pluck` ignores a preload it does not need.
    PAGINATED_RELATION_VALUES = %i[select lock].freeze

    def for_relation(records, key)
      unless records.klass <= model
        raise ConfigurationError,
              "`for` expects a relation for #{model.name}, got #{records.klass}"
      end

      assert_subqueryable!(records)
      return for_paginated_relation(records, key) if paginated?(records)
      scope = records.except(*UNUSED_RELATION_VALUES)
      # `offset(0)` skips nothing, but ActiveRecord still emits a LIMIT for it,
      # and MySQL cannot subquery a LIMIT at all.
      scope = scope.except(:offset) if scope.offset_value&.zero?

      where(key => scope.select(key)).fetch
    end

    def paginated?(records)
      records.limit_value || records.offset_value.to_i.positive?
    end

    # Which rows a page holds depends on the order the subquery cannot carry -
    # and MySQL rejects `IN (SELECT ... LIMIT ...)` outright. So the page is
    # resolved to primary keys first: one extra, narrow statement, and the page
    # and its order are the relation's own. See `page_keys` for the one shape
    # that has to be loaded to be paged at all.
    def for_paginated_relation(records, key)
      scope = records.except(*PAGINATED_RELATION_VALUES)

      for_ids(page_keys(scope, key), key, strict: false)
    end

    # A relation that joins to preload counts its `LIMIT` in parent rows, and
    # only ActiveRecord knows how to page that - `pluck` would join first and
    # cut the page mid fan-out, handing back duplicates and too many of them.
    # So that page is resolved the way ActiveRecord resolves it, by loading it;
    # the caller asked for preloaded records anyway. Every other relation keeps
    # the cheap read: keys only, nothing instantiated.
    def page_keys(scope, key)
      return scope.pluck(key) unless scope.eager_loading? || scope.includes_values.any?

      scope.map { |record| record[key] }
    end

    # A grouped relation selects the primary key it does not group by, which is
    # not valid SQL - as a subquery or plucked.
    def assert_subqueryable!(records)
      return if records.group_values.empty?

      raise ConfigurationError,
            "`for` cannot subquery a relation with group/having; pass the records themselves: " \
            "`for(relation.to_a)`"
    end

    # Batching owns the ordering and the paging, so a chain that already pages
    # would silently get a different answer than `fetch` gives. A page size that
    # is not a positive integer reads nothing at all, or reads everything.
    def assert_batchable!(size)
      unless size.is_a?(Integer) && size.positive?
        raise ArgumentError, "page size must be a positive integer, got #{size.inspect}"
      end

      return unless paginated?(relation)

      raise ConfigurationError,
            "`find_each`/`in_batches` page the whole chain themselves; " \
            "drop the `limit`/`offset` or use `fetch`"
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

    # Bulk `.for` reorders rows to match the input and batching seeks past the
    # last one read; both need the primary key on the result.
    def primary_key_output(key)
      field = query_class.pluckr_schema.fields.find { |node| node.column.to_s == key.to_s }
      return field.output if field

      raise ConfigurationError,
            "#{query_class.name} needs `field :#{key}` (or `field :#{key}, as: ...`) " \
            "to align several results with the rows they came from"
    end

    def assert_record!(record)
      return if record.is_a?(model)

      got = record.is_a?(ActiveRecord::Base) ? record.class.name : record.inspect
      raise ConfigurationError, "`for` expects #{model.name} records, got #{got}"
    end
  end
end
