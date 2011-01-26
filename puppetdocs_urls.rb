require 'rubygems'
require 'mechanize'
require 'nokogiri'

class InvalidPuppetDocsUrl < Exception
end

class PuppetDocsUrlsPlugin < Plugin
	Config.register Config::ArrayValue.new('puppetdocs_urls.channelmap',
		:default => [], :requires_restart => false,
		:desc => "A map of channels to the base PuppetDocs URL that should be used " +
		         "in that channel.  Format for each entry in the list is " +
		         "#channel:http://puppetdocs.site/to/use. Enclose each option in double quotes " +
                         "and don't put a trailing slash on the base URL, please.")

	def help(plugin, topic = "")
		case topic
			when '':
				"PuppetDocs_urls: Convert link requests into Puppet Docs URLS. " +
				"I will watch the channel for likely references. " +
				"I can convert common references into URLs when I see them " +
                                "in the channel if they are prefixed with 'ref' or 'guides'. " +
                                "Hence you can query ref:type to get the Type Reference and " +
                                "guide:introduction to get the Puppet Introduction."
		end
	end

	def listen(m)
		# We're a conversation watcher, dammit, don't talk to me!
		return if m.address?

		# We don't handle private messages just yet, and we only handle regular
		# chat messages
		return unless m.kind_of?(PrivMessage) && m.public?

		refs = m.message.scan(/(?:^|\W)|ref:\w+|guide:\w+|guides:\w+)(?:$|\W)/).flatten

		# Do we have at least one possible reference?
		return unless refs.length > 0

		refs.each do |ref|
			debug "We're out to handle '#{ref}'"

			url, title = expand_reference(ref, m.target)

			return unless url

			# Try to address the message to the right person
			if m.message =~ /^(\S+)[:,]/
				addressee = "#{$1}: "
			else
				addressee = "#{m.sourcenick}: "
			end

			# So we have a valid URL, and addressee, and now we just have to... speak!
			m.reply "#{addressee}#{ref} is #{url}" + (title.nil? ? '' : " \"#{title}\"")
		end
	end

	def puppetdocsinfo(m, params)
		debug("Handling puppetdocsinfo request; params is #{params.inspect}")
		return unless m.kind_of?(PrivMessage)
		m.reply "I can't do puppetdocsinfo in private yet" and return unless m.public?

		url, title = expand_reference(params[:ref], m.target)

		if url.nil?
			# Error!  The user-useful error message is in the 'title'
			m.reply "#{m.sourcenick}: #{title}" if title
		else
			m.reply "#{m.sourcenick}: #{params[:ref]} is #{url}" + (title ? " \"#{title}\"" : '')
		end
	end

	private
	# Parse the PuppetDocs reference given in +ref+, and try to construct a URL
	# from +base+ to the resource.  Returns an array containing the URL
	def ref_into_url(base, ref)
		case ref
                        when /ref:(\w+\#?\w+)/:
                                [ref_url(base, $1), :ref]
		        when /guide:(\w+\#?\w+)/:
                                [guide_url(base, $1), :guide]
                        when /guides:(\w+\#?\w+)/:
                                [guide_url(base, $1), :guide]

                end
	end

	# Return the CSS query that will extract the 'title' (or at least some
	# sort of sensible information) out of a HTML document of the given
	# reftype.
	def css_query_for(reftype)
		case reftype
			when :ref:
				'h1'
			when :guide:
				'h1'
			else
				warning "Unknown reftype: #{reftype}"; nil
		end
	end

	# Return the base URL for the channel (passed in as +target+), or +nil+
	# if the channel isn't in the channelmap.
	#
	def base_url(target)
             @bot.config['puppetdocs_urls.channelmap'].each { |l|
                   l.scan(/^#{target}\:(.+)/) { |w| return $1 }
             }
	end

	def ref_url(base_url, ref)
		base_url + '/references/latest/' + ref + '.html'
	end

	def guide_url(base_url, ref)
		base_url + '/guides/' + ref + '.html'
	end

	# Turn a string (which is, presumably, a PuppetDocs reference of some sort)
	# into a URL and, if possible, a title.
	#
	# Since the URL associated with a PuppetDocs reference is specific to a particular
	# PuppetDocs instance, you also need to pass the channel into expand_reference,
	# so it knows which channel (and hence which PuppetDocs instance) you're
	# talking about.
	#
	# Returns an array of [url, title].  If url is nil, then the reference
	# was of an invalid type or dereferenced to an invalid URL.  In that
	# case, title will be an error message.  Otherwise, url will be a string
	# URL and title should be a brief useful description of the URL (although
	# it may well be nil if we don't know how to get a title for that type of
	# Trac reference).
	#
	def expand_reference(ref, channel)
		debug "Expanding reference #{ref} in #{channel}"
                base = base_url(channel)

                debug "The base url for #{channel} is #{base}"

		# If we're not in a channel with a mapped base URL...
		return [nil, "I don't know about PuppetDocs URLs for this channel - please add a channelmap for this channel"] if base.nil?

		begin
			url, reftype = ref_into_url(base, ref)
			css_query = css_query_for(reftype)

			content = unless css_query.nil?
				# Rip up the page and tell us what you saw
				page_element_contents(base, url, css_query)
			else
				# We don't know how to get meaningful info out of this page, so
				# just validate that it actually loads
				page_element_contents(url, 'h1')
				nil
			end

			[url, content]
		rescue InvalidPuppetDocsUrl => e
			error("InvalidPuppetDocsUrl returned: #{e.message}")
			return [nil, "I'm afraid I don't understand '#{ref}' or I can't find a page for it.  Sorry."]
		rescue Exception => e
			error("Error (#{e.class}) while fetching URL #{url}: #{e.message}")
			e.backtrace.each {|l| error(l)}
			return [nil, "#{url} #{e.message} #{e.class} - An error occured while I was trying to look up the URL.  Sorry."]
		end
	end

	# Return the contents of the first element that matches +css_query+ in
	# the given +url+, or else raise InvalidPuppetDocsUrl if the page doesn't
	# respond with 200 OK.
	#
	def page_element_contents(base, url, css_query)
                Mechanize.html_parser = Nokogiri::HTML
                a = Mechanize.new { |agent|
                    agent.user_agent_alias = 'Mac Safari'
                }

                @page  = a.get(url)

                raise InvalidPuppetDocsUrl.new("#{url} returned response code #{page.code}.") unless @page.code == '200'

                elem = @page.search(css_query).first
		unless elem
			warning("Didn't find '#{css_query}' in page.")
			return
		end
		debug("Found '#{elem.inner_text}' with '#{css_query}'")
		elem.inner_text.gsub("\n", ' ').gsub(/\s+/, ' ').strip
	end
end

plugin = PuppetDocsUrlsPlugin.new
plugin.map 'puppetdocsinfo :ref'
