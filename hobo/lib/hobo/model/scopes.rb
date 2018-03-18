module Hobo
  module Model
    module Scopes

      ::ActiveRecord::Associations::Builder::Association::VALID_OPTIONS << :scope

      def self.included_in_class(klass)
        klass.class_eval do
          extend ClassMethods
        end
      end

      module ClassMethods

        include AutomaticScopes

        include ApplyScopes

      end

    end
  end
end
