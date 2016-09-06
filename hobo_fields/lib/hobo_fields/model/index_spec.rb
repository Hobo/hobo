module HoboFields
  module Model

    class IndexSpec

      def initialize(model, fields, options={})
        @model = model
        self.table = options.delete(:table_name) || model.table_name
        self.fields = Array.wrap(fields).*.to_s
        self.name = options.delete(:name) || default_name
        self.unique = options.delete(:unique) || false
        if options[:where]
          self.where = "#{options.delete(:where)}"
          self.where = "(#{self.where})" unless self.where.start_with?('(')
        end
      end

      attr_accessor :table, :fields, :name, :unique, :where

      # extract IndexSpecs from an existing table
      def self.for_model(model, old_table_name=nil)
        t = old_table_name || model.table_name
        model.connection.indexes(t).map do |i|
          self.new(model, i.columns, :name => i.name, :unique => i.unique, :where => i.where, :table_name => old_table_name) unless model.ignore_indexes.include?(i.name)
        end.compact
      end

      def default_name
        @model.connection.index_name(table, :column => fields)
      end

      def to_add_statement(new_table_name)
        r = "add_index #{new_table_name.to_sym.inspect}, #{fields.*.to_sym.inspect}"
        r += ", :unique => true" if unique
        r += ", :where => #{self.where.inspect}" if self.where.present?
        if name.length > @model.connection.index_name_length
          r += ", :name => #{name[0,@model.connection.index_name_length].inspect}"
          $stderr.puts("WARNING: index name #{name} too long, trimming")
        elsif name != default_name
          r += ", :name => #{name.inspect}"
        end
        r
      end

      def hash
        [table, fields, name, unique, where].hash
      end

      def ==(v)
        v.hash == hash
      end
      alias_method :eql?, :==
    end

  end
end
