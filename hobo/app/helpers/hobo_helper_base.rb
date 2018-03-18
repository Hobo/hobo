module HoboHelperBase

    def add_to_controller(controller)
      controller.send(:include, self)
    end

end
