Dryml.precompile_taglibs if File.basename($0) != "rake" && Rails.env.production?

### Speed improvements in development mode ###

# Although with Rails 3.2 dev mode is much faster, after saving a file it still reloads a lot of things
# For example, if you save a controller and reload the page, it can take several seconds to respond
# Same thing with Dryml (very annoying when you are editing and instantly trying the app)

# These are a couple of options to improve performance
# NOTE: You will lose automatic generation of routes and pages/cards/forms (you will need to restart the app)
# ::Rails.application.config.hobo.fast_dev_mode = true
# ::Rails.application.config.hobo.cached_tags = ["hobo_bootstrap", "hobo_rapid", "forms.dryml", "cards.dryml", "main_nav.dryml", "pages.dryml"]
# # Along with the previous options, uncomment these lines
# Rails::Generators.invoke('hobo:routes', %w[-f -q])
# Dryml::DrymlGenerator.run

# # Get rid of an annoying bug in the log
# RailsDevelopmentBoost.async = false if defined?(RailsDevelopmentBoost)

# Apart from these, please set these in config/environments/development.rb:
# - config.action_controller.perform_caching = true. This will make <hobo_cache> work (I recomment to use it in main_nav, as it's a very slow piece of code)
# - config.assets.debug = false. This will reduce the amount of files sent to the browser.

# And more optimizations!
# - Install rails dev boost (https://github.com/thedarkone/rails-dev-boost)
# - Install turbolinks (http://hobocentral.net/blog/2012/12/07/turbolinks/)
