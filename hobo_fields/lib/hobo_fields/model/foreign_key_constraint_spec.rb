module HoboFields
  module Model
    class ForeignKeyConstraintSpec

      def initialize(from_model, to_table, options={})
        @from_model = from_model
        self.from_table = options.delete(:from_table) || from_model.table_name
        self.to_table = to_table
        self.column = options.delete(:column) || default_column
        self.primary_key = options.delete(:primary_key) || default_primary_key
        self.on_delete = options.delete(:on_delete) if options[:on_delete]
        self.on_update = options.delete(:on_update) if options[:on_update]
        self.name = options.delete(:name) || default_name
      end

      attr_accessor :from_table, :to_table, :name, :column, :primary_key, :on_delete, :on_update

      # extract ForeignKeyConstraintSpecs from an existing table
      def self.for_model(model, old_table_name=nil)
        t = old_table_name || model.table_name
        model.connection.foreign_keys(t).map do |fkd|
          self.new(model, fkd.to_table, :from_table => fkd.from_table, :name => fkd.name, :column => fkd.column, :primary_key => fkd.primary_key, :on_delete => fkd.on_delete, :on_update => fkd.on_update) unless model.ignore_fk_constraints.include?(fkd.name)
        end.compact
      end

      def default_name
        # This private Rails method is currently (2015-11-04) the only way to
        # find the hashed constraint name that Rails automatically generates.
        @from_model.connection.send(:foreign_key_name, from_table, :column => column)
      end

      def default_column
        @from_model.connection.foreign_key_column_for(to_table)
      end

      def default_primary_key
        # Rails assumes that the primary key of the target table is 'id' unless otherwise
        # specified; it doesn't care about any primary_key= calls on the target model, if
        # there even is one. This is documented in
        # ActiveRecord::ConnectionAdapters::SchemaStatements::add_foreign_key
        # and implemented in
        # ActiveRecord::ConnectionAdapters::ForeignKeyDefinition::default_primary_key
        "id"
      end

      def to_add_statement(new_table_name)
        r = "add_foreign_key #{new_table_name.to_sym.inspect}, #{to_table.to_sym.inspect}"
        r += ", :column => #{column.inspect}" unless column == default_column
        r += ", :primary_key => #{primary_key.inspect}" unless primary_key == default_primary_key
        r += ", :name => #{name.inspect}" if name != default_name
        r += ", :on_delete => #{on_delete.to_sym.inspect}" if self.on_delete.present?
        r += ", :on_update => #{on_update.to_sym.inspect}" if self.on_update.present?
        r
      end

      def hash
        [from_table, to_table, name, column, primary_key, on_delete, on_update].hash
      end

      def ==(v)
        v.hash == hash
      end
      alias_method :eql?, :==

    end
  end
end
