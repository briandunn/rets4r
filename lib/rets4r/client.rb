# RETS4R Client
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
require 'rets4r/auth'
require 'rets4r/client/dataobject'
require 'thread'
require 'logger'

# See the bottom of this file for important loading instructions.

# An implementation of the RETS protocol in Ruby.
module RETS4R
	# This class delegates to an underlying implementation that has support
	# for the selected protocol version.
	class Client
		OUTPUT_RAW	= 0	# Nothing done. Simply returns the XML.
		OUTPUT_DOM	= 1	# Returns a DOM object (REXML)	**** NO LONGER SUPPORTED! ****
		OUTPUT_RUBY	= 2 # Returns a RETS::Data object
		
		METHOD_GET	= 'GET'
		METHOD_POST = 'POST'
		METHOD_HEAD = 'HEAD'
		
		DEFAULT_OUTPUT			= OUTPUT_RUBY
		DEFAULT_METHOD			= METHOD_GET
		SUPPORTED_RETS_VERSIONS	= []

		def self.default_rets_version
			@default_rets_version
		end

		def self.default_rets_version=(version)
			@default_rets_version = version
		end

		attr_accessor :mimemap, :logger, :delegate
		
		# Constructor
		# 
		# Requires the URL to the RETS server and takes an optional output format. The output format
		# determines the type of data returned by the various RETS transaction methods.
		def initialize(url, output = DEFAULT_OUTPUT, &block)
			raise Unsupported.new('DOM output is no longer supported.') if output == OUTPUT_DOM
			@url, @output = url, output
			set_rets_version(RETS4R::Client.default_rets_version, &block)
		end
		
		def set_rets_version(version, &block)
			logger.debug {SUPPORTED_RETS_VERSIONS.inspect} if logger
			if (SUPPORTED_RETS_VERSIONS.include? version)
				logger.debug {"Setting RETS version to #{version.inspect}"} if logger
				@delegate_class = RETS4R::Implementations.const_get("Client#{version.gsub(/\D/, '')}")
				logger.debug {"Underlying implementation: #{@delegate_class.name}"} if logger
				@delegate = @delegate_class.new(self, @url, @output, &block)
			else
				raise Unsupported.new("The client does not support RETS version '#{version}'.")
			end
		end
		
		def get_rets_version
			(get_header('RETS-Version') || "").gsub("RETS/", "")
		end
		
		# Provide more Ruby-like attribute accessors instead of get/set methods
		alias_method :rets_version=, :set_rets_version
		alias_method :rets_version, :get_rets_version
		
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
		def login(username, password, &block)
			delegate_to(:login, username, password, &block)
		end
		
		# Logs out of the RETS server.
		def logout()
			delegate_to(:logout)
		end
		
		# Requests Metadata from the server. An optional type and id can be specified to request
		# subsets of the Metadata. Please see the RETS specification for more details on this.
		# The format variable tells the server which format to return the Metadata in. Unless you
		# need the raw metadata in a specified format, you really shouldn't specify the format.
		#
		# If called with a block, yields the results and returns the value of the block, or
		# returns the metadata directly.
		def get_metadata(type = 'METADATA-SYSTEM', id = '*', format = 'COMPACT', &block)
			delegate_to(:get_metadata, type, id, format, &block)
		end
		
		# Performs a GetObject transaction on the server. For details on the arguments, please see
		# the RETS specification on GetObject requests.
		def get_object(resource, type, id, location = 1)
			delegate_to(:get_metadata, resource, type, id, location, &block)
		end
		
		# Peforms a RETS search transaction. Again, please see the RETS specification for details
		# on what these parameters mean. The options parameter takes a hash of options that will
		# added to the search statement.
		def search(search_type, klass, query, options = false, &block)
			delegate_to(:search, search_type, klass, query, options, &block)
		end
		
		# Delegates to an underlying Client15 or Client17 class.
		def delegate_to(*args, &block)
			method = args.shift
			args.unshift(self)
			@delegate.send(method, *args, &block)
		end
		
		# Provides a proxy class to allow for net/http to log its debug to the logger.
		class HTTPDebugLogger #:nodoc:
			def initialize(logger)
				@logger = logger
			end
			
			def <<(data)
				@logger.debug(data)
			end
		end
		
		#### Exceptions ####
		
		# This exception should be thrown when a generic client error is encountered.
		class ClientException < Exception
		end
		
		# This exception should be thrown when there is an error with the parser, which is 
		# considered a subcomponent of the RETS client. It also includes the XML data that
		# that was being processed at the time of the exception.
		class ParserException < ClientException
			attr_accessor :file
		end
		
		# The client does not currently support a specified action.
		class Unsupported < ClientException
		end
		
		# A general RETS level exception was encountered. This would include HTTP and RETS 
		# specification level errors as well as informative mishaps such as authentication being
		# required for access.
		class RETSException < Exception
		end
		
		# There was a problem with logging into the RETS server.
		class LoginError < RETSException
		end
		
		# For internal client use only, it is thrown when the a RETS request is made but a password
		# is prompted for.
		class AuthRequired < RETSException
		end
	end
end 

# Find and require all of our client implementations.  The last protocol
# version loaded will be the default version.  We have to do this here
# because RETS4R::Client must be loaded and parsed before hand.
Dir[File.join(File.dirname(__FILE__), "implementations", "client[0-9]*.rb")].sort.each do |f|
	require f
end
