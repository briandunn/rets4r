# RETS4R Client15
#
# Copyright (c) 2006 Scott Patterson <scott.patterson@digitalaun.com>
#
# This program is copyrighted free software by Scott Patterson.  You can
# redistribute it and/or modify it under the same terms of Ruby's license;
# either the dual license version in 2003 (see the file RUBYS), or any later
# version.
#
#	TODO
#		1.0 Support (Adding this support should be fairly easy)
#		2.0 Support (Adding this support will be very difficult since it is a completely different methodology)
#		Case-insensitive header

require 'digest/md5'
require 'net/http'
require 'uri'
require 'cgi'
require 'rets4r/client'
require 'rets4r/auth'
require 'rets4r/client/dataobject'
require 'thread'
require 'logger'

module RETS4R
module Implementations
	class Client15
		RETS4R::Client.default_rets_version = '1.5'
		RETS4R::Client::SUPPORTED_RETS_VERSIONS << '1.5'
		
		OUTPUT_RAW	= RETS4R::Client::OUTPUT_RAW
		OUTPUT_DOM	= RETS4R::Client::OUTPUT_DOM
		OUTPUT_RUBY	= RETS4R::Client::OUTPUT_RUBY
		
		METHOD_GET	= 'GET'
		METHOD_POST	= 'POST'
		METHOD_HEAD	= 'HEAD'
		
		DEFAULT_OUTPUT			= OUTPUT_RUBY
		DEFAULT_METHOD			= METHOD_GET
		DEFAULT_RETRY			= 2
		DEFAULT_USER_AGENT		= 'RETS4R/0.8.2'
		CAPABILITY_LIST			= ['Action', 'ChangePassword', 'GetObject', 'Login', 'LoginComplete', 'Logout', 'Search', 'GetMetadata', 'Update']

		SUPPORTED_PARSERS = [] # This will be populated by parsers as they load
		
		# We load our parsers here so that they can modify the client class appropriately. Because
		# the default parser will be the first parser to list itself in the DEFAULT_PARSER array,
		# we need to require them in the order of preference. Hence, XMLParser is loaded first because
		# it is preferred to REXML since it is much faster.
		require 'rets4r/client/parser/xmlparser'
		require 'rets4r/client/parser/rexml'
		
		# Set it as the first
		DEFAULT_PARSER = SUPPORTED_PARSERS[0]

		attr_accessor :mimemap, :logger
		
		# Constructor
		# 
		# Requires the URL to the RETS server and takes an optional output format. The output format
		# determines the type of data returned by the various RETS transaction methods.
		def initialize(parent, url, output = DEFAULT_OUTPUT, &block)
			self.logger = parent.logger
			logger.debug {"#{self.class.name}.initialize(#{[parent, url, output, block].inspect})"} if logger
			raise Unsupported.new('DOM output is no longer supported.') if output == RETS4R::Client::OUTPUT_DOM
			
			@urls     = { 'Login' => URI.parse(url) }
			@nc       = 0
			@headers  = {
				'User-Agent'   => DEFAULT_USER_AGENT, 
				'Accept'       => '*/*', 
				'RETS-Version' => "RETS/1.5", 
				'RETS-Session-ID' => '0'
				}
			@request_method = DEFAULT_METHOD
			@parser_class   = DEFAULT_PARSER
			@semaphore      = Mutex.new
			@output         = output
			
			self.mimemap		= {
				'image/jpeg'  => 'jpg',
				'image/gif'   => 'gif'
				}
				
			block.call(parent) if block
		end
		
		def get_rets_version
			"1.5"
		end
		alias_method :rets_version, :get_rets_version
		
		# We only allow external read access to URLs because they are internally set based on the
		# results of various queries.
		def urls
			@urls
		end
		
		# Parses the provided XML returns it in the specified output format.
		# Requires an XML string and takes an optional output format to override the instance output
		# format variable. We current create a new parser each time, which seems a bit wasteful, but
		# it allows for the parser to be changed in the middle of a session as well as XML::Parser
		# requiring a new instance for each execution...that could be encapsulated within its parser
		# class,though, so we should benchmark and see if it will make a big difference with the 
		# REXML parse, which I doubt.
		def parse(xml, output = false)
			if xml == ''
				trans = Transaction.new()
				trans.reply_code = -1
				trans.reply_text = 'No transaction body was returned!'
			end
			
			if output == OUTPUT_RAW || @output == OUTPUT_RAW
				xml
			else
				begin
					parser = @parser_class.new
					parser.logger = logger
					parser.output = output ? output : @output

					parser.parse(xml)
				rescue
					raise ParserException.new($!)
				end
			end
		end
		
		# Setup Methods (accessors and mutators)
		def set_output(output = DEFAULT_OUTPUT)
			@output = output
		end
		
		def get_output
			@output
		end
		
		def set_parser_class(klass, force = false)
			if force || SUPPORTED_PARSERS.include?(klass)
				@parser_class = klass
			else
				message = "The parser class '#{klass}' is not supported!"
				logger.debug(message) if logger
				
				raise Unsupported.new(message)
			end
		end
		
		def get_parser_class
			@parser_class
		end
		
		def set_header(name, value)
			if value.nil? then
				@headers.delete(name)
			else
				@headers[name] = value
			end
			
			logger.debug("Set header '#{name}' to '#{value}'") if logger
		end
		
		def get_header(name)
			@headers[name]
		end
		
		def set_user_agent(name)
			set_header('User-Agent', name)
		end
		
		def get_user_agent
			get_header('User-Agent')
		end
		
		def set_request_method(method)
			@request_method = method
		end
		
		def get_request_method
			@request_method
		end
		
		# Provide more Ruby-like attribute accessors instead of get/set methods
		alias_method :user_agent=, :set_user_agent
		alias_method :user_agent, :get_user_agent
		alias_method :request_method=, :set_request_method
		alias_method :request_method, :get_request_method
		alias_method :parser_class=, :set_parser_class
		alias_method :parser_class, :get_parser_class
		alias_method :output=, :set_output
		alias_method :output, :get_output
		
		#### RETS Transaction Methods ####
		#
		# Most of these transaction methods mirror the RETS specification methods, so if you are 
		# unsure what they mean, you should check the RETS specification. The latest version can be
		# found at http://www.rets.org
		
		# Attempts to log into the server using the provided username and password.
		#
		# If called with a block, the results of the login action are yielded,
		# and logout is called when the block returns.  In that case, #login
		# returns the block's value. If called without a block, returns the
		# result.
		#
		# As specified in the RETS specification, the Action URL is called and
		# the results made available in the #secondary_results accessor of the
		# results object.
		def login(parent, username, password, &block)
			@username = username
			@password = password
			
			# We are required to set the Accept header to this by the RETS 1.5 specification.
			set_header('Accept', '*/*')
			
			response = request(@urls['Login'])
			
			# Parse response to get other URLS
			results = self.parse(response.body, OUTPUT_RUBY)
			
			if (results.success?)
				CAPABILITY_LIST.each do |capability|
					next unless results.response[capability]
					base = @urls['Login'].clone
					base.path = results.response[capability]
					
					@urls[capability] = base
				end
				
				logger.debug("Capability URL List: #{@urls.inspect}") if logger
			else
				raise LoginError.new(response.message + "(#{results.reply_code}: #{results.reply_text})")
			end
			
			if @output != OUTPUT_RUBY
				results = self.parse(response.body)
			end
			
			# Perform the mandatory get request on the action URL.
			results.secondary_response = perform_action_url
			
			# We only yield
			if block
				begin
					block.call(results)
				ensure
					self.logout(parent)
				end
			else
				results
			end
		end
		
		# Logs out of the RETS server.
		def logout(parent)
			# If no logout URL is provided, then we assume that logout is not necessary (not to 
			# mention impossible without a URL). We don't throw an exception, though, but we might
			# want to if this becomes an issue in the future.
			
			request(@urls['Logout']) if @urls['Logout']
		end
		
		# Requests Metadata from the server. An optional type and id can be specified to request
		# subsets of the Metadata. Please see the RETS specification for more details on this.
		# The format variable tells the server which format to return the Metadata in. Unless you
		# need the raw metadata in a specified format, you really shouldn't specify the format.
		#
		# If called with a block, yields the results and returns the value of the block, or
		# returns the metadata directly.
		def get_metadata(parent, type = 'METADATA-SYSTEM', id = '*', format = 'COMPACT', &block)
			header = {
				'Accept' => 'text/xml,text/plain;q=0.5'
			}
			
			data = {
				'Type'   => type,
				'ID'     => id,
				'Format' => format
			}
					
			response = request(@urls['GetMetadata'], data, header)
			
			result = self.parse(response.body)
			
			if block
				block.call result
			else
				result
			end
		end
		
		# Performs a GetObject transaction on the server. For details on the arguments, please see
		# the RETS specification on GetObject requests.
		def get_object(parent, resource, type, id, location = 1, &block)
			header = {
				'Accept' => mimemap.keys.join(',')
			}
			
			data = {
				'Resource' => resource,
				'Type'     => type,
				'ID'       => id,
				'Location' => location.to_s
			}
			
			response = request(@urls['GetObject'], data, header)
			results  = nil
			
			if response['content-type'].include?('multipart/parallel')
				content_type = process_content_type(response['content-type'])

				objects = []

				parts = response.body.split("--#{content_type['boundary']}")
				parts.shift # Get rid of the initial boundary
				
				parts.each do |part|
					(raw_header, raw_data) = part.split("\r\n\r\n")
					
					next unless raw_data
					
					data_header = process_header(raw_header)
					
					extension = 'unknown'
					extension = self.mimemap[data_header['Content-Type']] if self.mimemap[data_header['Content-Type']]
					
					objects << DataObject.new(data_header, raw_data)
				end 
				
				results = objects
			else
				info = {
					'content-type' => response['content-type'],
					'Object-ID'    => response['Object-ID'],
					'Content-ID'   => response['Content-ID']
				}

				results = [DataObject.new(info, response.body)] if response['Content-Length'].to_i > 100
			end
			
			if block
				block.call results
			end
						
			return results
		end
		
		# Peforms a RETS search transaction. Again, please see the RETS specification for details
		# on what these parameters mean. The options parameter takes a hash of options that will
		# added to the search statement.
		def search(parent, search_type, klass, query, options = false, &block)
			header = {}
		
			# Required Data
			data = {
				'SearchType' => search_type,
				'Class'      => klass,
				'Query'      => query,
				'QueryType'  => 'DMQL2',
				'Format'     => 'COMPACT',
				'Count'      => '0'
			}
			
			# Options
			#--
			# We might want to switch this to merge!, but I've kept it like this for now because it
			# explicitly casts each value as a string prior to performing the search, so we find out now
			# if can't force a value into the string context. I suppose it doesn't really matter when
			# that happens, though...
			#++
			options.each { |k,v| data[k] = v.to_s } if options
			
			response = request(@urls['Search'], data, header)
			
			results = self.parse(response.body)
			
			if block
				block.call results
			else
				return results
			end
		end
		
		private
	
		def process_content_type(text)
			content = {}
			
			field_start = text.index(';')

			# The -1 is to remove the semi-colon (";")
			content['content-type'] = text[0..(field_start - 1)].strip
			fields = text[field_start..-1]
			
			parts = text.split(';')
			
			parts.each do |part|
				(name, value) = part.split('=')
				
				content[name.strip] = value ? value.strip : value
			end
			
			content
		end
		
		# Processes the HTTP header
		#-- 
		# Could we switch over to using CGI for this?
		#++
		def process_header(raw)
			header = {}
			
			raw.each do |line|
				(name, value) = line.split(':')
				
				header[name.strip] = value.strip if name && value
			end
			
			header
		end
		
		# Given a hash, it returns a URL encoded query string.
		def create_query_string(hash)
			parts = hash.map {|key,value| "#{CGI.escape(key)}=#{CGI.escape(value)}"}
			return parts.join('&')
		end
		
		# This is the primary transaction method, which the other public methods make use of.
		# Given a url for the transaction (endpoint) it makes a request to the RETS server.
		# 
		#-- 
		# This needs to be better documented, but for now please see the public transaction methods
		# for how to make use of this method.
		#++
		def request(url, data = {}, header = {}, method = @request_method, retry_auth = DEFAULT_RETRY)
			response = ''
			
			@semaphore.lock
			
			http = Net::HTTP.new(url.host, url.port)
			
			if logger && logger.debug?
				http.set_debug_output HTTPDebugLogger.new(logger)
			end
			
			http.start do |http|
				begin
					uri = url.path
					
					if ! data.empty? && method == METHOD_GET
						uri += "?#{create_query_string(data)}"
					end

					headers = @headers
					headers.merge(header) unless header.empty?
					
					logger.debug(headers.inspect) if logger
					
					@semaphore.unlock
										
					response = http.get(uri, headers)
										
					@semaphore.lock
					
					if response.code == '401'
						# Authentication is required
						raise AuthRequired
					else
						cookies = []
						if set_cookies = response.get_fields('set-cookie') then
							set_cookies.each do |cookie|
								cookies << cookie.split(";").first
							end
						end
						set_header('Cookie', cookies.join("; ")) unless cookies.empty?
						set_header('RETS-Session-ID', response['RETS-Session-ID']) if response['RETS-Session-ID']
					end
				rescue AuthRequired
					@nc += 1

					if retry_auth > 0
						retry_auth -= 1
						set_header('Authorization', Auth.authenticate(response, @username, @password, url.path, method, @headers['RETS-Request-ID'], get_user_agent, @nc))
						retry
					end
				end		
				
				logger.debug(response.body) if logger
			end
			
			@semaphore.unlock if @semaphore.locked?
			
			return response
		end
		
		# If an action URL is present in the URL capability list, it calls that action URL and returns the
		# raw result. Throws a generic RETSException if it is unable to follow the URL.
		def perform_action_url
			begin
				if @urls.has_key?('Action')
					return request(@urls['Action'], {}, {}, METHOD_GET)
				end
			rescue
				raise RETSException.new("Unable to follow action URL: '#{$!}'.")
			end
		end
		
		# Provides a proxy class to allow for net/http to log its debug to the logger.
		class HTTPDebugLogger
			def initialize(logger)
				@logger = logger
			end
			
			def <<(data)
				@logger.debug(data)
			end
		end
	end
end
end 
