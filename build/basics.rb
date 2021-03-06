#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010, 2011, 2012 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'rubygems'
require 'pathname'
require 'fileutils'
require 'phusion_passenger'
PhusionPassenger.locate_directories
require 'phusion_passenger/packaging'
require 'phusion_passenger/platform_info'
require 'phusion_passenger/platform_info/operating_system'
require 'phusion_passenger/platform_info/binary_compatibility'
require 'phusion_passenger/platform_info/ruby'
require 'phusion_passenger/platform_info/apache'
require 'phusion_passenger/platform_info/curl'
require 'phusion_passenger/platform_info/zlib'
require 'phusion_passenger/platform_info/compiler'
require 'phusion_passenger/platform_info/cxx_portability'

include PhusionPassenger
include PhusionPassenger::PlatformInfo

require 'build/rake_extensions'
require 'build/cplusplus_support'

#################################################

class TemplateRenderer
	def initialize(filename)
		require 'erb' if !defined?(ERB)
		@erb = ERB.new(File.read(filename))
		@erb.filename = filename
	end

	def render
		return @erb.result(binding)
	end

	def render_to(filename)
		puts "Creating #{filename}"
		text = render
		# When packaging, some timestamps may be modified. The user may not
		# have write access to the source root (for example, when Passenger
		# Standalone is compiling its runtime), so we only write to the file
		# when necessary.
		if File.writable?(filename) || File.read(filename) != text
			File.open(filename, 'w') do |f|
				f.write(text)
			end
		end
	end
end

def string_option(name, default_value = nil)
	value = ENV[name]
	if value.nil? || value.empty?
		return default_value
	else
		return value
	end
end

def boolean_option(name, default_value = false)
	value = ENV[name]
	if value.nil? || value.empty?
		return default_value
	else
		return value == "yes" || value == "on" || value == "true" || value == "1"
	end
end

def maybe_wrap_in_ccache(command)
	if boolean_option('USE_CCACHE', false)
		return "ccache #{command}"
	else
		return command
	end
end

#################################################

if string_option('OUTPUT_DIR')
	OUTPUT_DIR = string_option('OUTPUT_DIR') + "/"
else
	OUTPUT_DIR = "buildout/"
end

verbose true if !boolean_option('REALLY_QUIET')
if boolean_option('STDERR_TO_STDOUT')
	# Just redirecting the file descriptor isn't enough because
	# data written to STDERR might arrive in an unexpected order
	# compared to STDOUT.
	STDERR.reopen(STDOUT)
	Object.send(:remove_const, :STDERR)
	STDERR = STDOUT
	$stderr = $stdout
end

if boolean_option('CACHING', true) && !boolean_option('RELEASE')
	PlatformInfo.cache_dir = OUTPUT_DIR + "cache"
	FileUtils.mkdir_p(PlatformInfo.cache_dir)
end

#################################################

PACKAGE_NAME    = PhusionPassenger::PACKAGE_NAME
PACKAGE_VERSION = PhusionPassenger::VERSION_STRING
PACKAGE_SIGNING_KEY = string_option('PACKAGE_SIGNING_KEY', '0x0A212A8C')
MAINTAINER_NAME  = "Phusion"
MAINTAINER_EMAIL = "info@phusion.nl"

OPTIMIZE = boolean_option("OPTIMIZE")
CC       = maybe_wrap_in_ccache(string_option("CC", "gcc"))
CXX      = maybe_wrap_in_ccache(string_option("CXX", "g++"))
LIBEXT   = PlatformInfo.library_extension
USE_DMALLOC = boolean_option('USE_DMALLOC')
USE_EFENCE  = boolean_option('USE_EFENCE')
USE_ASAN    = boolean_option('USE_ASAN')
OPTIMIZATION_FLAGS = "#{PlatformInfo.debugging_cflags} -DPASSENGER_DEBUG -DBOOST_DISABLE_ASSERTS -fcommon".strip
OPTIMIZATION_FLAGS << " -O" if OPTIMIZE
OPTIMIZATION_FLAGS << " -feliminate-unused-debug-symbols -feliminate-unused-debug-types" if PlatformInfo.compiler_supports_feliminate_unused_debug?
OPTIMIZATION_FLAGS << " -fvisibility=hidden -DVISIBILITY_ATTRIBUTE_SUPPORTED" if PlatformInfo.compiler_supports_visibility_flag?
OPTIMIZATION_FLAGS << " -Wno-attributes" if PlatformInfo.compiler_supports_visibility_flag? &&
	PlatformInfo.compiler_visibility_flag_generates_warnings? &&
	PlatformInfo.compiler_supports_wno_attributes_flag?
OPTIMIZATION_FLAGS << " -fno-omit-frame-pointers" if USE_ASAN

# Agent-specific compiler flags.
AGENT_CFLAGS  = ""
AGENT_CFLAGS << " -faddress-sanitizer" if USE_ASAN
AGENT_CFLAGS.strip!

# Agent-specific linker flags.
AGENT_LDFLAGS = ""
AGENT_LDFLAGS << " #{PlatformInfo.dmalloc_ldflags}" if USE_DMALLOC
AGENT_LDFLAGS << " #{PlatformInfo.electric_fence_ldflags}" if USE_EFENCE
AGENT_LDFLAGS << " -faddress-sanitizer" if USE_ASAN
# Extra linker flags for backtrace_symbols() to generate useful output (see AgentsBase.cpp).
AGENT_LDFLAGS << " #{PlatformInfo.export_dynamic_flags}"
# Enable dead symbol elimination on OS X.
AGENT_LDFLAGS << " -Wl,-dead_strip" if RUBY_PLATFORM =~ /darwin/
AGENT_LDFLAGS.strip!

# Extra compiler flags that should always be passed to the C/C++ compiler.
# These should be included first in the command string, before anything else.
EXTRA_PRE_CFLAGS = string_option('EXTRA_PRE_CFLAGS', '').gsub("\n", " ")
EXTRA_PRE_CXXFLAGS = string_option('EXTRA_PRE_CXXFLAGS', '').gsub("\n", " ")
# These should be included last in the command string, even after PlatformInfo.portability_cflags.
EXTRA_CXXFLAGS = "-Wall -Wextra -Wno-unused-parameter -Wno-parentheses -Wpointer-arith -Wwrite-strings -Wno-long-long"
EXTRA_CXXFLAGS << " -Wno-missing-field-initializers" if PlatformInfo.compiler_supports_wno_missing_field_initializers_flag?
EXTRA_CXXFLAGS << " -mno-tls-direct-seg-refs" if PlatformInfo.requires_no_tls_direct_seg_refs? && PlatformInfo.compiler_supports_no_tls_direct_seg_refs_option?
# Work around Clang warnings in ev++.h.
EXTRA_CXXFLAGS << " -Wno-ambiguous-member-template" if PlatformInfo.cxx_is_clang?
EXTRA_CXXFLAGS << " #{OPTIMIZATION_FLAGS}" if !OPTIMIZATION_FLAGS.empty?
EXTRA_CXXFLAGS << " " << string_option('EXTRA_CXXFLAGS').gsub("\n", " ") if string_option('EXTRA_CXXFLAGS')
EXTRA_CXXFLAGS << " -DPASSENGER_DISABLE_THREAD_LOCAL_STORAGE" if !boolean_option('PASSENGER_THREAD_LOCAL_STORAGE', true)

# Extra linker flags that should always be passed to the linker.
# These should be included first in the command string, before anything else.
EXTRA_PRE_LDFLAGS  = string_option('EXTRA_PRE_LDFLAGS', '').gsub("\n", " ")
# These should be included last in the command string, even after PlatformInfo.portability_ldflags.
EXTRA_LDFLAGS  = string_option('EXTRA_LDFLAGS', '').gsub("\n", " ")


AGENT_OUTPUT_DIR          = string_option('AGENT_OUTPUT_DIR', OUTPUT_DIR + "agents") + "/"
COMMON_OUTPUT_DIR         = string_option('COMMON_OUTPUT_DIR', OUTPUT_DIR + "common") + "/"
APACHE2_OUTPUT_DIR        = string_option('APACHE2_OUTPUT_DIR', OUTPUT_DIR + "apache2") + "/"
LIBEV_OUTPUT_DIR          = string_option('LIBEV_OUTPUT_DIR', OUTPUT_DIR + "libev") + "/"
LIBEIO_OUTPUT_DIR         = string_option('LIBEIO_OUTPUT_DIR', OUTPUT_DIR + "libeio") + "/"
ruby_extension_archdir    = PlatformInfo.ruby_extension_binary_compatibility_id
RUBY_EXTENSION_OUTPUT_DIR = string_option('RUBY_EXTENSION_OUTPUT_DIR',
	OUTPUT_DIR + "ruby/" + ruby_extension_archdir) + "/"
PKG_DIR                   = string_option('PKG_DIR', "pkg")


# Whether to use the vendored libev or the system one.
USE_VENDORED_LIBEV = boolean_option("USE_VENDORED_LIBEV", true)
# Whether to use the vendored libeio or the system one.
USE_VENDORED_LIBEIO = boolean_option("USE_VENDORED_LIBEIO", true)
