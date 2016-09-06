module Generators
  module Hobo
    module Migration

      class HabtmModelShim < Struct.new(:join_table, :foreign_keys, :fk_constraint_specs, :connection)

        def self.from_reflection(refl)
          result = self.new
          result.join_table = refl.options[:join_table].to_s
          result.foreign_keys = [refl.foreign_key.to_s, refl.association_foreign_key.to_s].sort
          # this may fail in weird ways if HABTM is running across two DB connections (assuming that's even supported)
          # figure that anybody who sets THAT up can deal with their own migrations...
          result.connection = refl.active_record.connection

          result.fk_constraint_specs = [
            HoboFields::Model::ForeignKeyConstraintSpec.new(
              result,
              refl.active_record.table_name,
              from_table: result.join_table,
              column: refl.foreign_key
            ),
            HoboFields::Model::ForeignKeyConstraintSpec.new(
              result,
              refl.table_name,
              from_table: result.join_table,
              column: refl.association_foreign_key
            )
          ]

          result
        end

        def table_name
          self.join_table
        end

        def table_exists?
          ActiveRecord::Migration.table_exists? table_name
        end

        def field_specs
          i = 0
          foreign_keys.inject({}) do |h, v|
            # some trickery to avoid an infinite loop when FieldSpec#initialize tries to call model.field_specs
            h[v] = HoboFields::Model::FieldSpec.new(self, v, :integer, :position => i)
            i += 1
            h
          end
        end

        def primary_key
          false
        end

        def index_specs
          []
        end
      end

      class Migrator

        class Error < RuntimeError; end

        @ignore_models = []
        @ignore_tables = []

        class << self
          attr_accessor :ignore_models, :ignore_tables, :disable_indexing, :disable_fk_constraints
        end

        def self.run(renames={})
          g = Migrator.new
          g.renames = renames
          g.generate
        end

        def self.default_migration_name
          existing = Dir["#{Rails.root}/db/migrate/*hobo_migration*"]
          max = existing.grep(/([0-9]+)\.rb$/) { $1.to_i }.max
          n = max ? max + 1 : 1
          "hobo_migration_#{n}"
        end

        def initialize(ambiguity_resolver={})
          @ambiguity_resolver = ambiguity_resolver
          @drops = []
          @renames = nil
        end

        attr_accessor :renames


        def load_rails_models
          Rails.application.eager_load!
        end


        # Returns an array of model classes that *directly* extend
        # ActiveRecord::Base, excluding anything in the CGI module
        def table_model_classes
          load_rails_models
          ActiveRecord::Base.send(:descendants).reject {|c| (c.base_class != c) || c.name.starts_with?("CGI::") }
        end


        def self.connection
          ActiveRecord::Base.connection
        end
        def connection; self.class.connection; end


        def self.fix_native_types(types)
          case connection.class.name
          when /mysql/i
            types[:integer][:limit] ||= 11
            types[:text][:limit] ||= 65535
          end
          types
        end

        def self.native_types
          @native_types ||= fix_native_types connection.native_database_types
        end
        def native_types; self.class.native_types; end

        # list habtm join tables
        def habtm_tables
          reflections = Hash.new { |h, k| h[k] = Array.new }
          ActiveRecord::Base.send(:descendants).map do |c|
            c.reflect_on_all_associations(:has_and_belongs_to_many).each do |a|
              reflections[a.options[:join_table].to_s] << a
            end
          end
          reflections
        end

        # Returns an array of model classes and an array of table names
        # that generation needs to take into account
        def models_and_tables
          ignore_model_names = Migrator.ignore_models.*.to_s.*.underscore
          all_models = table_model_classes
          hobo_models = all_models.select { |m| m.try.include_in_migration && m.name.underscore.not_in?(ignore_model_names) }
          non_hobo_models = all_models - hobo_models
          db_tables = connection.tables - Migrator.ignore_tables.*.to_s - non_hobo_models.reject { |t| t.try.hobo_shim? }.*.table_name
          [hobo_models, db_tables]
        end


        # return a hash of table renames and modifies the passed arrays so
        # that renamed tables are no longer listed as to_create or to_drop
        def extract_table_renames!(to_create, to_drop)
          if renames
            # A hash of table renames has been provided

            to_rename = {}
            renames.each_pair do |old_name, new_name|
              new_name = new_name[:table_name] if new_name.is_a?(Hash)
              next unless new_name

              if to_create.delete(new_name.to_s) && to_drop.delete(old_name.to_s)
                to_rename[old_name.to_s] = new_name.to_s
              else
                raise Error, "Invalid table rename specified: #{old_name} => #{new_name}"
              end
            end
            to_rename

          elsif @ambiguity_resolver
            @ambiguity_resolver.call(to_create, to_drop, "table", nil)

          else
            raise Error, "Unable to resolve migration ambiguities"
          end
        end


        def extract_column_renames!(to_add, to_remove, table_name)
          if renames
            to_rename = {}
            column_renames = renames._?[table_name.to_sym]
            if column_renames
              # A hash of table renames has been provided

              column_renames.each_pair do |old_name, new_name|
                if to_add.delete(new_name.to_s) && to_remove.delete(old_name.to_s)
                  to_rename[old_name.to_s] = new_name.to_s
                else
                  raise Error, "Invalid rename specified: #{old_name} => #{new_name}"
                end
              end
            end
            to_rename

          elsif @ambiguity_resolver
            @ambiguity_resolver.call(to_add, to_remove, "column", "#{table_name}.")

          else
            raise Error, "Unable to resolve migration ambiguities in table #{table_name}"
          end
        end


        def always_ignore_tables
          # TODO: figure out how to do this in a sane way and be compatible with 2.2 and 2.3 - class has moved
          sessions_table = CGI::Session::ActiveRecordStore::Session.table_name if
            defined?(CGI::Session::ActiveRecordStore::Session) &&
            defined?(ActionController::Base) &&
            ActionController::Base.session_store == CGI::Session::ActiveRecordStore
          ['schema_info', 'schema_migrations',  sessions_table].compact
        end


        def generate
          models, db_tables = models_and_tables
          models_by_table_name = {}
          models.each do |m|
            if !models_by_table_name.has_key?(m.table_name)
              models_by_table_name[m.table_name] = m
            elsif m.superclass==models_by_table_name[m.table_name].superclass.superclass
              # we need to ensure that models_by_table_name contains the
              # base class in an STI hierarchy
              models_by_table_name[m.table_name] = m
            end
          end
          # generate shims for HABTM models
          habtm_tables.each do |name, refls|
            models_by_table_name[name] = HabtmModelShim.from_reflection(refls.first)
          end
          model_table_names = models_by_table_name.keys

          to_create = model_table_names - db_tables
          to_drop = db_tables - model_table_names - always_ignore_tables
          to_change = model_table_names

          to_rename = extract_table_renames!(to_create, to_drop)

          renames = to_rename.map do |old_name, new_name|
            "rename_table #{old_name.to_sym.inspect}, #{new_name.to_sym.inspect}"
          end * "\n"
          undo_renames = to_rename.map do |old_name, new_name|
            "rename_table #{new_name.to_sym.inspect}, #{old_name.to_sym.inspect}"
          end * "\n"

          drops = to_drop.map do |t|
            "drop_table #{t.to_sym.inspect}"
          end * "\n"
          undo_drops = to_drop.map do |t|
            revert_table(t)
          end * "\n\n"

          creates = to_create.map do |t|
            create_table(models_by_table_name[t])
          end * "\n\n"
          undo_creates = to_create.map do |t|
            "drop_table #{t.to_sym.inspect}"
          end * "\n"

          changes = []
          undo_changes = []
          index_changes = []
          fk_constraint_changes = []
          undo_index_changes = []
          undo_fk_constraint_changes = []
          to_change.each do |t|
            model = models_by_table_name[t]
            table = to_rename.key(t) || model.table_name
            if table.in?(db_tables)
              change, undo = change_table(model, table)
              changes << change
              undo_changes << undo

              index_change, undo_index = change_indexes(model, table)
              index_changes << index_change.join("\n")
              undo_index_changes << undo_index.join("\n")

              fk_constraint_change, undo_fk_constraint = change_fk_constraints(model, table)
              fk_constraint_changes << fk_constraint_change.join("\n")
              undo_fk_constraint_changes << undo_fk_constraint.join("\n")
            end
          end

          # TODO Should do all FK drops before everything else
          up   = [renames, drops, creates, changes, index_changes, fk_constraint_changes].flatten.reject(&:blank?) * "\n\n"
          down = [undo_fk_constraint_changes, undo_changes, undo_renames, undo_drops, undo_creates, undo_index_changes].flatten.reject(&:blank?) * "\n\n"

          [up, down]
        end

        def create_table(model)
          longest_field_name = model.field_specs.values.map { |f| f.sql_type.to_s.length }.max
          if model.primary_key != "id"
            if model.primary_key
              primary_key_option = ", :primary_key => #{model.primary_key.to_sym.inspect}"
            else
              primary_key_option = ", :id => false"
            end
          end
          [
            ["create_table #{model.table_name.to_sym.inspect}#{primary_key_option} do |t|"],
            model.field_specs.values.sort_by{|f| f.position}.map {|f| create_field(f, longest_field_name)},
            ["end"],
            (Migrator.disable_indexing ? [] : create_indexes(model)),
            (Migrator.disable_fk_constraints ? [] : create_fk_constraints(model))
           ].flatten(1) * "\n"
        end

        def create_indexes(model)
          model.index_specs.map { |i| i.to_add_statement(model.table_name) }
        end

        def create_fk_constraints(model)
          model.fk_constraint_specs.map { |fkc| fkc.to_add_statement(model.table_name) }
        end

        def create_field(field_spec, field_name_width)
          args = [field_spec.name.inspect] + format_options(field_spec.options, field_spec.sql_type)
          "  t.%-*s %s" % [field_name_width, field_spec.sql_type, args.join(', ')]
        end

        def change_table(model, current_table_name)
          new_table_name = model.table_name

          db_columns = model.connection.columns(current_table_name).index_by{|c|c.name}
          key_missing = db_columns[model.primary_key].nil? && model.primary_key
          db_columns -= [model.primary_key]

          model_column_names = model.field_specs.keys.*.to_s
          db_column_names = db_columns.keys.*.to_s

          to_add = model_column_names - db_column_names
          to_add += [model.primary_key] if key_missing && model.primary_key
          to_remove = db_column_names - model_column_names
          to_remove = to_remove - [model.primary_key.to_sym] if model.primary_key

          to_rename = extract_column_renames!(to_add, to_remove, new_table_name)

          db_column_names -= to_rename.keys
          db_column_names |= to_rename.values
          to_change = db_column_names & model_column_names

          renames = to_rename.map do |old_name, new_name|
            "rename_column #{new_table_name.to_sym.inspect}, #{old_name.to_sym.inspect}, #{new_name.to_sym.inspect}"
          end
          undo_renames = to_rename.map do |old_name, new_name|
            "rename_column #{new_table_name.to_sym.inspect}, #{new_name.to_sym.inspect}, #{old_name.to_sym.inspect}"
          end

          to_add = to_add.sort_by {|c| model.field_specs[c].position }
          adds = to_add.map do |c|
            spec = model.field_specs[c]
            args = [spec.sql_type.to_sym.inspect] + format_options(spec.options, spec.sql_type)
            "add_column #{new_table_name.to_sym.inspect}, #{c.to_sym.inspect}, #{args * ', '}"
          end
          undo_adds = to_add.map do |c|
            "remove_column #{new_table_name.to_sym.inspect}, #{c.to_sym.inspect}"
          end

          removes = to_remove.map do |c|
            "remove_column #{new_table_name.to_sym.inspect}, #{c.to_sym.inspect}"
          end
          undo_removes = to_remove.map do |c|
            revert_column(current_table_name, c)
          end

          old_names = to_rename.invert
          changes = []
          undo_changes = []
          to_change.each do |c|
            col_name = old_names[c] || c
            col = db_columns[col_name]
            spec = model.field_specs[c]
            if spec.different_to?(col)
              change_spec = {}
              change_spec[:limit]     = spec.limit     unless spec.limit.nil? && col.limit.nil?
              change_spec[:precision] = spec.precision unless spec.precision.nil?
              change_spec[:scale]     = spec.scale     unless spec.scale.nil?
              change_spec[:null]      = spec.null      unless spec.null && col.null
              change_spec[:default]   = spec.default   unless spec.default.nil? && col.default.nil?
              change_spec[:comment]   = spec.comment   unless spec.comment.nil? && col.try.comment.nil?

              changes << "change_column #{new_table_name.to_sym.inspect}, #{c.to_sym.inspect}, " +
                ([spec.sql_type.to_sym.inspect] + format_options(change_spec, spec.sql_type, true)).join(", ")
              back = change_column_back(current_table_name, col_name)
              undo_changes << back unless back.blank?
            else
              nil
            end
          end.compact

          [(renames + adds + removes + changes) * "\n",
           (undo_renames + undo_adds + undo_removes + undo_changes) * "\n"]
        end

        def change_indexes(model, old_table_name)
          return [[],[]] if Migrator.disable_indexing || model.is_a?(HabtmModelShim)
          new_table_name = model.table_name
          existing_indexes = HoboFields::Model::IndexSpec.for_model(model, old_table_name)
          model_indexes = model.index_specs
          add_indexes = model_indexes - existing_indexes
          drop_indexes = existing_indexes - model_indexes
          undo_add_indexes = []
          undo_drop_indexes = []
          add_indexes.map! do |i|
            undo_add_indexes << drop_index(old_table_name, i.name)
            i.to_add_statement(new_table_name)
          end
          drop_indexes.map! do |i|
            undo_drop_indexes << i.to_add_statement(old_table_name)
            drop_index(new_table_name, i.name)
          end
          # the order is important here - adding a :unique, for instance needs to remove then add
          [drop_indexes + add_indexes, undo_add_indexes + undo_drop_indexes]
        end

        def drop_index(table, name)
          # see https://hobo.lighthouseapp.com/projects/8324/tickets/566
          # for why the rescue exists
          max_length = connection.index_name_length
          name = name[0,max_length] if name.length > max_length
          "remove_index #{table.to_sym.inspect}, :name => #{name.to_sym.inspect} rescue ActiveRecord::StatementInvalid"
        end

        def change_fk_constraints(model, old_table_name)
          return [[],[]] unless model.connection.supports_foreign_keys?
          return [[],[]] if Migrator.disable_fk_constraints || model.is_a?(HabtmModelShim)
          new_table_name = model.table_name
          existing_fk_constraints = HoboFields::Model::ForeignKeyConstraintSpec.for_model(model, old_table_name)
          model_fk_constraints = model.fk_constraint_specs
          add_fk_constraints = model_fk_constraints - existing_fk_constraints
          drop_fk_constraints = existing_fk_constraints - model_fk_constraints
          undo_add_fk_constraints = []
          undo_drop_fk_constraints = []
          add_fk_constraints.map! do |fkc|
            undo_add_fk_constraints << drop_fk_constraint(old_table_name, fkc.name)
            fkc.to_add_statement(new_table_name)
          end
          drop_fk_constraints.map! do |fkc|
            undo_drop_fk_constraints << fkc.to_add_statement(old_table_name)
            drop_fk_constraint(new_table_name, fkc.name)
          end
          [drop_fk_constraints + add_fk_constraints, undo_add_fk_constraints + undo_drop_fk_constraints]
        end

        def drop_fk_constraint(table, name)
          "remove_foreign_key #{table.to_sym.inspect}, :name => #{name.to_sym.inspect}"
        end

        def format_options(options, type, changing=false)
          options.map do |k, v|
            unless changing
              next if k == :limit && (type == :decimal || v == native_types[type][:limit])
              next if k == :null && v == true
            end
            "#{k.inspect} => #{v.inspect}"
          end.compact
        end


        def revert_table(table)
          res = StringIO.new
          ActiveRecord::SchemaDumper.send(:new, ActiveRecord::Base.connection).send(:table, table, res)
          res.string.strip.gsub("\n  ", "\n")
        end


        def column_options_from_reverted_table(table, column)
          revert = revert_table(table)
          if (md = revert.match(/\s*t\.column\s+"#{column}",\s+(:[a-zA-Z0-9_]+)(?:,\s+(.*?)$)?/m))
            # Ugly migration
            _, type, options = *md
          elsif (md = revert.match(/\s*t\.([a-z_]+)\s+"#{column}"(?:,\s+(.*?)$)?/m))
            # Sexy migration
            _, type, options = *md
            type = type.to_sym.inspect
          end
          [type, options]
        end


        def change_column_back(table, column)
          type, options = column_options_from_reverted_table(table, column)
          "change_column #{table.to_sym.inspect}, #{column.to_sym.inspect}, #{type}#{', ' + options.strip if options}"
        end


        def revert_column(table, column)
          type, options = column_options_from_reverted_table(table, column)
          "add_column #{table.to_sym.inspect}, #{column.to_sym.inspect}, #{type}#{', ' + options.strip if options}"
        end

      end

    end
  end
end

