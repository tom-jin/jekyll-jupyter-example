require 'json'
require 'tmpdir'
JEKYLL_MIN_VERSION_3 = Gem::Version.new(Jekyll::VERSION) >= Gem::Version.new('3.0.0') unless defined? JEKYLL_MIN_VERSION_3

module Jekyll
  module Jupyter
    module Utils
      def self.has_front_matter?(delegate_method, notebook_ext_re, path)
        ::File.extname(path) =~ notebook_ext_re ? true : delegate_method.call(path)
      end
    end
  end

  module Converters
    class NotebookConverter < Converter
      IMPLICIT_ATTRIBUTES = %W(
        env=site env-site site-gen=jekyll site-gen-jekyll builder=jekyll builder-jekyll jekyll-version=#{Jekyll::VERSION}
      )
      HEADER_BOUNDARY_RE = /(?<=\p{Graph})\n\n/

      safe true

      highlighter_prefix "\n"
      highlighter_suffix "\n"

      def initialize(config)
        @config = config
        config['notebook'] ||= 'nbconvert'
        notebook_ext = (config['notebook_ext'] ||= 'ipynb')
        notebook_ext_re = (config['notebook_ext_re'] = /^\.(?:#{notebook_ext.tr ',', '|'})$/ix)
        config['notebook_page_attribute_prefix'] ||= 'page'
        unless (nbconvert_config = (config['nbconvert'] ||= {})).frozen?
          # NOTE convert keys to symbols
          nbconvert_config.keys.each do |key|
            nbconvert_config[key.to_sym] = nbconvert_config.delete(key)
          end
          nbconvert_config[:safe] ||= 'safe'
          (nbconvert_config[:attributes] ||= []).tap do |attributes|
            attributes.unshift('notitle', 'hardbreaks', 'idprefix', 'idseparator=-', 'linkattrs')
            attributes.concat(IMPLICIT_ATTRIBUTES)
          end
          if JEKYLL_MIN_VERSION_3
            if (del_method = ::Jekyll::Utils.method(:has_yaml_header?))
              unless (new_method = ::Jekyll::Jupyter::Utils.method(:has_front_matter?)).respond_to?(:curry)
                new_method = new_method.to_proc # Ruby < 2.2
              end
              del_method.owner.define_singleton_method(del_method.name, new_method.curry[del_method][notebook_ext_re])
            end
          end
          nbconvert_config.freeze
        end
      end

      def setup
        return if @setup
        @setup = true
        case @config['notebook']
        when 'nbconvert'
          unless system('jupyter nbconvert --help > /dev/null')
            STDERR.puts 'Cannot find jupyter. Check virtual enviroments are active or run:'
            STDERR.puts '  $ [sudo] pip install jupyter'
            raise ::Jekyll::Errors::FatalException.new('Missing dependency: jupyter')
          end
        else
          STDERR.puts "Invalid AsciiDoc processor: #{@config['notebook']}"
          STDERR.puts '  Valid options are [ nbconvert ]'
          raise FatalException.new("Invalid AsciiDoc processor: #{@config['notebook']}")
        end
      end

      def matches(ext)
        ext =~ @config['notebook_ext_re']
      end

      def output_ext(ext)
        '.html'
      end

      def convert(content)
        return content if content.empty?
        setup
        case @config['notebook']
        when 'nbconvert'
          json = JSON.parse(content)
          json["cells"].shift
          body = json.to_json
          Dir.mktmpdir do |dir|
            File.open(File.join(dir,"convert.ipynb"), 'w') { |f| f.write(body) }
            system("jupyter", "nbconvert", "--to", "html", "--template",
            "basic", "--output-dir", dir, "#{dir}/convert.ipynb",)
            File.read("#{dir}/convert.html")
          end
        else
          warn 'Unknown AsciiDoc converter. Passing through unparsed content.'
          content
        end
      end

      def load_header(content)
        setup
        # NOTE merely an optimization; if this doesn't match, the header still gets isolated by the processor
        header = content.split(HEADER_BOUNDARY_RE, 2)[0]
        case @config['notebook']
        when 'nbconvert'
          # NOTE return a document even if header is empty because attributes may be inherited from config
          first_cell = JSON.parse(header)["cells"][0]["source"]
          first_cell.join("")
        else
          warn 'Unknown AsciiDoc converter. Cannot load document header.'
        end
      end
    end
  end

  module Generators
    # Promotes select AsciiDoc attributes to Jekyll front matter
    class AsciiDocPreprocessor < Generator
      module NoLiquid
        def render_with_liquid?
          false
        end
      end

      def generate(site)
        notebook_converter = JEKYLL_MIN_VERSION_3 ?
            site.find_converter_instance(Jekyll::Converters::NotebookConverter) :
            site.getConverterImpl(Jekyll::Converters::NotebookConverter)
        notebook_converter.setup
        unless (page_attr_prefix = site.config['notebook_page_attribute_prefix']).empty?
          page_attr_prefix = %(#{page_attr_prefix}-)
        end
        page_attr_prefix_l = page_attr_prefix.length

        site.pages.each do |page|
          if notebook_converter.matches(page.ext)
            next unless (doc = notebook_converter.load_header(page.content))
            page.data.update(SafeYAML.load(doc))
            page.extend NoLiquid unless page.data['liquid']
          end
        end

        (JEKYLL_MIN_VERSION_3 ? site.posts.docs : site.posts).each do |post|
          if notebook_converter.matches(JEKYLL_MIN_VERSION_3 ? post.data['ext'] : post.ext)
            next unless (doc = notebook_converter.load_header(post.content))
            post.data.update(SafeYAML.load(doc))
            post.extend NoLiquid unless post.data['liquid']
          end
        end
      end
    end
  end

  module Filters
    # Convert an AsciiDoc string into HTML output.
    #
    # input - The AsciiDoc String to convert.
    #
    # Returns the HTML formatted String.
    def notebookify(input)
      site = @context.registers[:site]
      converter = JEKYLL_MIN_VERSION_3 ?
          site.find_converter_instance(Jekyll::Converters::NotebookConverter) :
          site.getConverterImpl(Jekyll::Converters::NotebookConverter)
      converter.convert(input)
    end
  end
end
