class GitScribe
  module Generate
    # generate the new media
    def gen(args = [])
      @done = {}  # what we've generated already

      type = first_arg(args) || 'all'
      prepare_output_dir

      gather_and_process

      types = type == 'all' ? OUTPUT_TYPES : [type]

      ret = false
      output = []
      Dir.chdir("output") do
        types.each do |out_type|
          call = 'do_' + out_type
          if self.respond_to? call
            ret = self.send call
          else
            die "NOT A THING: #{call}"
          end
        end
        # clean up
        `rm #{BOOK_FILE}`
        ret
      end
    end

    def prepare_output_dir
      Dir.mkdir('output') rescue nil
      Dir.chdir('output') do
        Dir.mkdir('stylesheets') rescue nil
        from_stdir = File.join(SCRIBE_ROOT, 'stylesheets')
        FileUtils.cp_r from_stdir, '.'
      end
    end

    def a2x(type)
      "a2x -f #{type} -d book "
    end

    def a2x_wss(type)
      a2x(type) + " --stylesheet=stylesheets/handbookish.css"
    end

    def do_pdf
      info "GENERATING PDF"
      # TODO: syntax highlighting (fop?)
      ex("asciidoc -b docbook #{BOOK_FILE}")
      strparams = {'callout.graphics' => 0,
                   'navig.graphics' => 0,
                   'admon.textlabel' => 1,
                   'admon.graphics' => 0}
      param = strparams.map { |k, v| "--stringparam #{k} #{v}" }.join(' ')
      cmd = "xsltproc  --nonet #{param} --output #{local('book.fo')} #{base('docbook-xsl/fo.xsl')} #{local('book.xml')}"
      ex(cmd)
      cmd = "fop -fo #{local('book.fo')} -pdf #{local('book.pdf')}"
      ex(cmd)
      #puts `#{a2x('pdf')} -v --fop #{BOOK_FILE}`
      if $?.exitstatus == 0
        'book.pdf'
      end
    end

    def do_epub
      info "GENERATING EPUB"
      # TODO: look for custom stylesheets
      cmd = "#{a2x_wss('epub')} -v #{BOOK_FILE}"
      if ex(cmd)
        'book.epub'
      end
    end

    def do_mobi
      do_html
      info "GENERATING MOBI"
      # --cover 'cover.png'
      # --authors 'Author Name'
      # --comments "licensed under CC"
      # --language 'en'
      cmd = "ebook-convert book.html book.mobi --level1-toc '//h:h1' --level2-toc '//h:h2' --level3-toc '//h:h3'"
      if ex(cmd)
        'book.mobi'
      end
    end

    def do_html
      return true if @done['html']
      info "GENERATING HTML"
      # TODO: look for custom stylesheets
      #puts `#{a2x_wss('xhtml')} -v #{BOOK_FILE}`
      styledir = local('stylesheets')
      cmd = "asciidoc -a stylesdir=#{styledir} -a theme=handbookish #{BOOK_FILE}"
      if ex(cmd)
        @done['html'] == true
        'book.html'
      end
    end

    def do_site
      info "GENERATING SITE"
      # TODO: check if html was already done
      ex("asciidoc -b docbook #{BOOK_FILE}")
      xsldir = base('docbook-xsl/xhtml')
      ex("xsltproc --stringparam html.stylesheet stylesheets/handbookish.css --nonet #{xsldir}/chunk.xsl book.xml")

      source = File.read('index.html')
      html = Nokogiri::HTML.parse(source, nil, 'utf-8')

      sections = []
      c = -1

      # each chapter
      html.css('.toc > dl').each do |section|
        section.children.each do |item|
          if item.name == 'dt' # section
            c += 1
            sections[c] ||= {'number' => c}
            link = item.css('a').first
            sections[c]['title'] = title = link.text
            sections[c]['href'] = href = link['href']
            clean_title = title.downcase.gsub(/[^a-z0-9\-_]+/, '_') + '.html'
            sections[c]['link'] = clean_title
            if href[0, 10] == 'index.html'
              sections[c]['link'] = 'title.html'
            end
            sections[c]['sub'] = []
          end
          if item.name == 'dd' # subsection
            item.css('dt').each do |sub|
              link = sub.css('a').first
              data = {}
              data['title'] = title = link.text
              data['href'] = href = link['href']
              data['link'] = sections[c]['link'] + '#' + href.split('#').last
              sections[c]['sub'] << data
            end
          end
        end
      end

      book_title = html.css('head > title').text
      content = html.css('body > div')[1]
      content.css('.toc').first.remove
      content = content.inner_html

      sections.each do |s|
        content.gsub!(s['href'], s['link'])
      end

      template_dir = File.join(SCRIBE_ROOT, 'site', 'default')

      # copy the template files in
      files = Dir.glob(template_dir + '/*')
      FileUtils.cp_r files, '.'

      Liquid::Template.file_system = Liquid::LocalFileSystem.new(template_dir)
      index_template = Liquid::Template.parse(File.read(File.join(template_dir, 'index.html')))
      page_template = Liquid::Template.parse(File.read(File.join(template_dir, 'page.html')))

      # write the index page
      main_data = { 
        'book_title' => book_title,
        'sections' => sections
      }
      File.open('index.html', 'w+') do |f|
        f.puts index_template.render( main_data )
      end

      # write the title page
      File.open('title.html', 'w+') do |f|
        data = { 
          'title' => sections.first['title'],
          'sub' => sections.first['sub'],
          'prev' => {'link' => 'index.html', 'title' => "Main"},
          'home' => {'link' => 'index.html', 'title' => "Home"},
          'next' => sections[1],
          'content' => content
        }
        data.merge!(main_data)
        f.puts page_template.render( data )
      end

      # write the other pages
      sections.each_with_index do |section, i|

        if i > 0 # skip title page
          source = File.read(section['href'])
          html = Nokogiri::HTML.parse(source, nil, 'utf-8')

          content = html.css('body > div')[1].to_html
          sections.each do |s|
            content.gsub!(s['href'], s['link'])
          end

          File.open(section['link'], 'w+') do |f|
            next_section = nil
            if i <= sections.size
              next_section = sections[i+1]
            end
            data = { 
              'title' => section['title'],
              'sub' => section['sub'],
              'prev' => sections[i-1],
              'home' => {'link' => 'index.html', 'title' => "Home"},
              'next' => next_section,
              'content' => content
            }
            data.merge!(main_data)
            f.puts page_template.render( data )
          end
          #File.unlink(section['href'])

          info i
          info section['title']
          info section['href']
          info section['link']
        end

        #File.unlink
      end
      sections
    end

    # create a new file by concatenating all the ones we find
    def gather_and_process
      files = Dir.glob("book/*")
      FileUtils.cp_r files, 'output'
    end

    def ex(command)
      out = `#{command} 2>&1`
      info out
      $?.exitstatus == 0
    end

  end
end
