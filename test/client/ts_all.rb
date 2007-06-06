$:.unshift File.join(File.dirname(__FILE__))

require 'test/unit'
require 'tc_auth.rb'
require 'test/client/implementations/tc_client15.rb'
require 'tc_metadataindex.rb'
require 'parser/tc_rexml.rb'
require 'parser/tc_xmlparser.rb'
