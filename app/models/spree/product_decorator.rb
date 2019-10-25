module Spree::ProductDecorator
  def self.prepended(base)
    base.include Elasticsearch::Model

    base.index_name Spree::ElasticsearchSettings.index
    base.document_type "spree_product"

    base.mapping _all: { analyzer: "nGram_analyzer", search_analyzer: "whitespace_analyzer" } do
      indexes :name, type: "text" do
        indexes :name, type: "text", boost: 100, analyzer: "nGram_analyzer", index: true
        indexes :untouched, type: "keyword", index: false
      end

      indexes :description, analyzer: "snowball"
      indexes :available_on, type: "date", format: "dateOptionalTime"
      indexes :discontinue_on, type: "date", format: "dateOptionalTime"
      indexes :price, type: "double"
      indexes :sku, type: "keyword", index: true
      indexes :taxon_ids, type: "keyword", index: true
      indexes :properties, type: "keyword", index: true
      indexes :classifications, type: "nested" do
        indexes :taxon_id, type: "integer"
        indexes :position, type: "integer"
      end
    end

    def base.get(product_id)
      Elasticsearch::Model::Response::Result.new(__elasticsearch__.client.get index: index_name, type: document_type, id: product_id)
    end
  end

  def as_indexed_json(options = {})
    result = as_json({
      methods: [:price, :sku],
      only: [:available_on, :discontinue_on, :description, :name],
      include: {
        classifications: {
          only: [:taxon_id, :position],
        },
        variants: {
          only: [:sku],
          include: {
            option_values: {
              only: [:name, :presentation],
            },
          },
        },
      },
    })
    result[:properties] = property_list unless property_list.empty?
    result[:taxon_ids] = taxons.map(&:self_and_ancestors).flatten.uniq.map(&:id) unless taxons.empty?
    result
  end

  # Inner class used to query elasticsearch. The idea is that the query is dynamically build based on the parameters.
  class Spree::Product::ElasticsearchQuery
    include ::Virtus.model

    attribute :from, Integer, default: 0
    attribute :price_min, Float
    attribute :price_max, Float
    attribute :properties, Hash
    attribute :query, String
    attribute :taxons, Array
    attribute :browse_mode, Boolean
    attribute :sorting, String

    # When browse_mode is enabled, the taxon filter is placed at top level. This causes the results to be limited, but facetting is done on the complete dataset.
    # When browse_mode is disabled, the taxon filter is placed inside the filtered query. This causes the facets to be limited to the resulting set.

    # Method that creates the actual query based on the current attributes.
    # The idea is to always to use the following schema and fill in the blanks.
    # {
    #   query: {
    #     filtered: {
    #       query: {
    #         query_string: { query: , fields: [] }
    #       }
    #       filter: {
    #         and: [
    #           { terms: { taxons: [] } },
    #           { terms: { properties: [] } }
    #         ]
    #       }
    #     }
    #   }
    #   filter: { range: { price: { lte: , gte: } } },
    #   sort: [],
    #   from: ,
    #   aggregations:
    # }
    def to_hash
      q = { match_all: {} }
      unless query.blank? # nil or empty
        q = { query_string: { query: query, fields: ["name^5", "description", "sku"], default_operator: "AND", use_dis_max: true } }
      end
      query = q

      and_filter = []
      unless @properties.nil? || @properties.empty?
        # transform properties from [{"key1" => ["value_a","value_b"]},{"key2" => ["value_a"]}
        # to { terms: { properties: ["key1||value_a","key1||value_b"] }
        #    { terms: { properties: ["key2||value_a"] }
        # This enforces "and" relation between different property values and "or" relation between same property values
        properties = @properties.map { |key, value| [key].product(value) }.map do |pair|
          and_filter << { terms: { properties: pair.map { |property| property.join("||") } } }
        end
      end

      # Only sort by classification if taxon present
      @sorting = nil if @sorting == "classification" and taxons.empty?

      sorting = case @sorting
                when "name_asc"
                  [{ "name.untouched" => { order: "asc" } }, { price: { order: "asc" } }, "_score"]
                when "name_desc"
                  [{ "name.untouched" => { order: "desc" } }, { price: { order: "asc" } }, "_score"]
                when "price_asc"
                  [{ "price" => { order: "asc" } }, { "name.untouched" => { order: "asc" } }, "_score"]
                when "price_desc"
                  [{ "price" => { order: "desc" } }, { "name.untouched" => { order: "asc" } }, "_score"]
                when "classification"
                  [{ "classifications.position" => {
                    mode: "min",
                    order: "asc",
                    nested: {
                      path: "classifications",
                      filter: {
                        term: { "classifications.taxon_id" => taxons.first },
                      },
                    },
                  } }]
                when "score"
                  ["_score", { "name.untouched" => { order: "asc" } }, { price: { order: "asc" } }]
                else
                  [{ "name.untouched" => { order: "asc" } }, { price: { order: "asc" } }, "_score"]
                end

      # aggregations
      aggregations = {
        price: { stats: { field: "price" } },
        properties: { terms: { field: "properties", order: { _count: "asc" }, size: 1000000 } },
        taxon_ids: { terms: { field: "taxon_ids", size: 1000000 } },
      }

      # basic skeleton
      result = {
        min_score: 0.1,
        query: { bool: {} },
        sort: sorting,
        from: from,
        aggregations: aggregations,
      }

      # add query and filters to filterd
      result[:query][:bool][:must] = query
      # taxon and property filters have an effect on the facets
      and_filter << { terms: { taxon_ids: taxons } } unless taxons.empty?
      # only return products that are available
      and_filter << { range: { available_on: { lte: "now" } } }
      and_filter << { bool: { should: [{ bool: { must_not: { exists: { field: "discontinue_on" } } } }, { range: { discontinue_on: { gte: "now/1h" } } }] } }

      result[:query][:bool][:filter] = and_filter unless and_filter.empty?

      # add price filter outside the query because it should have no effect on facets
      if price_min && price_max && (price_min < price_max)
        result[:post_filter] = { range: { price: { gte: price_min, lte: price_max } } }
      end

      result
    end
  end

  private

  def property_list
    product_properties.map { |pp| "#{pp.property.name}||#{pp.value}" }
  end
end

Spree::Product.prepend(Spree::ProductDecorator)
