require 'erubi'

module Dryml

  class DRYMLBuilder

    def initialize(template)
      @template = template
      @build_instructions = nil # set to [] on the first add_build_instruction
      @part_names = []
    end

    attr_reader :template, :environment

    def template_path
      template.template_path
    end


    def set_environment(environment)
      @environment = environment
    end


    def ready?(mtime, d=false)
      @build_instructions && @last_build_mtime && @last_build_mtime >= mtime
    end


    def start
      @part_names.clear
      @build_instructions = []
    end


    def add_build_instruction(type, params)
      @build_instructions << params.merge(:type => type)
    end


    def add_part(name, src, line_num)
      raise DrymlException.new("duplicate part: #{name}", template_path, line_num) if name.in?(@part_names)
      add_build_instruction(:def, :src => src, :line_num => line_num)
      @part_names << name
    end


    def <<(params)
      @build_instructions << params
    end


    def render_page_source(src, local_names)
      locals = local_names.map{|l| "#{l} = __local_assigns__[:#{l}];"}.join(' ')

      ("def render_page(__page_this__, __local_assigns__); " +
            "#{locals} new_object_context(__page_this__) do " +
            src +
           "; output_buffer; end; end")
    end


      begin
        require "erubis"
      rescue LoadError
        # nothing
      else
        erubis = Class.new(::Erubis::Eruby) do
          # :nodoc: all
          def add_preamble(src)
            @newline_pending = 0
            src << "@output_buffer = output_buffer || ActionView::OutputBuffer.new;"
          end

          def add_text(src, text)
            return if text.empty?

            if text == "\n"
              @newline_pending += 1
            else
              src << "@output_buffer.safe_append='"
              src << "\n" * @newline_pending if @newline_pending > 0
              src << escape_text(text)
              src << "'.freeze;"

              @newline_pending = 0
            end
          end

          # Erubis toggles <%= and <%== behavior when escaping is enabled.
          # We override to always treat <%== as escaped.
          def add_expr(src, code, indicator)
            case indicator
            when "=="
              add_expr_escaped(src, code)
            else
              super
            end
          end

          BLOCK_EXPR = /\s*((\s+|\))do|\{)(\s*\|[^|]*\|)?\s*\Z/

          def add_expr_literal(src, code)
            flush_newline_if_pending(src)
            if BLOCK_EXPR.match?(code)
              src << "@output_buffer.append= " << code
            else
              src << "@output_buffer.append=(" << code << ");"
            end
          end

          def add_expr_escaped(src, code)
            flush_newline_if_pending(src)
            if BLOCK_EXPR.match?(code)
              src << "@output_buffer.safe_expr_append= " << code
            else
              src << "@output_buffer.safe_expr_append=(" << code << ");"
            end
          end

          def add_stmt(src, code)
            flush_newline_if_pending(src)
            super
          end

          def add_postamble(src)
            flush_newline_if_pending(src)
            src << "@output_buffer.to_s"
          end

          def flush_newline_if_pending(src)
            if @newline_pending > 0
              src << "@output_buffer.safe_append='#{"\n" * @newline_pending}'.freeze;"
              @newline_pending = 0
            end
          end
        end
    end

    def erb_process(erb_src)
      trim_mode = ActionView::Template::Handlers::ERB.erb_trim_mode
      erb = ::Erubi::Engine.new(erb_src, :trim_mode => trim_mode)
      res = erb.src
      res = res.dup
      if res.respond_to? :force_encoding
        res.force_encoding(erb_src.encoding)
      end
      res
    end

    def build(local_names, auto_taglibs, src_mtime)

      auto_taglibs.each { |t| import_taglib(t) }

      @build_instructions._?.each do |instruction|
        name = instruction[:name]
        case instruction[:type]
        when :eval
          @environment.class_eval(instruction[:src], template_path, instruction[:line_num])

        when :def
          src = erb_process(instruction[:src])
          @environment.class_eval(src, template_path, instruction[:line_num])

        when :render_page
          method_src = render_page_source(erb_process(instruction[:src]), local_names)
          @environment.compiled_local_names = local_names
          @environment.class_eval(method_src, template_path, instruction[:line_num])

        when :include
          import_taglib(instruction)

        when :module
          import_module(name.constantize, instruction[:as])

        when :alias_method
          @environment.send(:alias_method, instruction[:new], instruction[:old])

        else
          raise RuntimeError.new("DRYML: Unknown build instruction :#{instruction[:type]}, " +
                                 "building #{template_path}")
        end
      end
      @last_build_mtime = src_mtime
    end


    def import_taglib(options)
      if options[:module]
        import_module(options[:module].constantize, options[:as])
      else
        template_dir = File.dirname(template_path)
        options = options.merge(:template_dir => template_dir, :source_template => template_path)

        Taglib.get(options).each do |taglib|
          taglib.import_into(@environment, options[:as])
        end
      end
    end


    def import_module(mod, as=nil)
      raise NotImplementedError if as
      @environment.send(:include, mod)
    end
  end
end

