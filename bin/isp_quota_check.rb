#!/usr/bin/ruby
# File:		isp_quota_check.rb
# Author:	Grant Jackson
# Package:	N/A
# Environment:	Ruby 2.0.0
#
# Copyright (C) 2012-2014
# Licensed under GPLv3. GNU GENERAL PUBLIC LICENSE, Version 3, 29 June 2007
# http://www.gnu.org/licenses/
#
# Based on node-usage.sh (GPLv3) by Dale Hopkins at http://dale.id.au/pub/node-usage/
#
# Can be run from command line or via your crontab, eg.
#   0 8 * * * isp_quota_check.rb >> /var/tmp/download_remain.log 2>> $HOME/log/download_remain.err
#
##############################################################################
require 'net/http'
require 'rexml/document'
require 'date'

require 'openssl'
require 'base64' 
require 'fileutils'

##############################################################################
# A module to store common ISP quota-check constants and methods
##############################################################################
module IspQuotaCheckCommon
  # Web-services constants
  ISP_WS_BASE_URI = "https://customer-webtools-api.internode.on.net/api/v1.5"
  ISP_WS_SERVICE_XPATH = 'internode/api/services/service'
  ISP_WS_USAGE_XPATH = 'internode/api/traffic'

  # Cipher constants (used by default for storing encrypted ISP username/password)
  SYMMETRIC_ALG = "aes-256-cbc"
  DIR = "#{ENV['HOME']}/.ispc"
  TARGET_PATH = "#{DIR}/target.dump"
end

##############################################################################
# A class to get an ISP services or usage web page
##############################################################################
class WebPage
  include IspQuotaCheckCommon

  ############################################################################
  # Create a web page XML object for either ADSL services or usage.
  # type = :services or :usage. If type is :usage then we must supply one of
  # the text services which we retrieved from the :services page.
  ############################################################################
  def initialize(type, service=nil)
    if ![:services, :usage].include?(type) || type == :usage && service.class.nil?
      @page = nil
    else
      extra = type == :usage ? "#{service}/usage" : ''
      uri_str = "#{ISP_WS_BASE_URI}/#{extra}"

      uri = URI(uri_str)
      req = Net::HTTP::Get.new uri.request_uri
      begin
        # For testing: uncomment the "req.basic_auth" line; replace
        # MY_ISP_USERNAME & MY_PASSWORD with real values; comment
        # out the "eval" line. After testing remember to *delete*
        # (not just comment out) all traces of your username and
        # password.
        #
        # req.basic_auth('MY_ISP_USERNAME', 'MY_PASSWORD')
        eval IspConnect.decrypt_from_file

        page = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https'){|http| http.request(req)}
      rescue Exception => ex
        STDERR.puts "#{Time.now.strftime('%F %T')} Error when preparing or attempting to connect to #{uri_str}: #{ex}"
        Usage.usage_exit("\nPerhaps you haven't run this program with the --setup option?") if ex.class == Errno::ENOENT
      end
      @page = page.body
    end
  end

  ############################################################################
  # Return the web page as a string
  ############################################################################
  def to_s
    @page
  end
end

##############################################################################
# Optional class to allow ISP username and password to be stored in a
# separate file in an encrypted form. Although the encryption may be
# strong, the security is easily defeated. The purpose of this class
# is simply to make the ISP connection details not obvious to the
# casual observer.
##############################################################################
class IspConnect
  include IspQuotaCheckCommon

  ############################################################################
  # Human user interface to allow setting of username and password.
  # Method will exit when complete.
  ############################################################################
  def self.ui_get_and_store_details
    puts <<-UI_INTRO_EOM.gsub(/^\t*/, '')

	Generating connection details for your ISP account
	--------------------------------------------------

	You will be asked for your username and password, which will then
	be stored in an encrypted form.

	You only need to run this connection set-up program:
	- before you run the ISP quota-check for the first time, or
	- after you change your ISP username or password
    UI_INTRO_EOM

    ARGV.clear		# Prevent gets from reading command line args
    if File.exists?(TARGET_PATH)
      puts "\nFile #{TARGET_PATH} already exists."
      printf "Are you sure you want to overwrite it? y/n [n] "
      is_overwrite = gets.chomp.strip
      unless %w{y yes}.include?(is_overwrite.downcase)
        puts "Quitting without overwriting file."
        exit 0
      end
    end

    printf "\nEnter ISP username: "
    user = gets.chomp.strip
    printf "Enter ISP password: "
    password = gets.chomp.strip

    statement = "req.basic_auth('#{user}', '#{password}')"
    puts "Writing encrypted statement: #{statement}"
    encrypt_to_file(statement)
    exit 0
  end

  ############################################################################
  # Encrypt the data and write it to a file
  ############################################################################
  def self.encrypt_to_file(data)
    cipher = OpenSSL::Cipher::Cipher.new(SYMMETRIC_ALG)
    cipher.encrypt

    key = cipher.random_key
    iv = cipher.random_iv
    cipher.key = key
    cipher.iv = iv

    encrypted = cipher.update(data) + cipher.final
    FileUtils.mkdir_p DIR
    File.write(TARGET_PATH, Base64.encode64( Marshal.dump([key, iv, encrypted]) ))
    FileUtils.chmod(0600, TARGET_PATH)		# Only readable by user
  end

  ############################################################################
  # Read the data from a file and decrypt it
  ############################################################################
  def self.decrypt_from_file
    cipher = OpenSSL::Cipher::Cipher.new(SYMMETRIC_ALG)
    cipher.decrypt

    key, iv, encrypted = Marshal.load( Base64.decode64(File.read(TARGET_PATH)) )
    cipher.key = key
    cipher.iv = iv
    cipher.update(encrypted) + cipher.final
  end
end

##############################################################################
# A class to read all the ISP services (plans) for a particular ISP account.
#
# A 'service' response page looks like this:
# <internode>
#  <api>
#   <services count="1">
#    <service type="Personal_ADSL" href="/api/v1.5/2776709">987654321</service>
#   </services>
#  </api>
# </internode>
##############################################################################
class Services
  include IspQuotaCheckCommon

  attr_reader :services

  ############################################################################
  # Get a list of ISP services on this account
  ############################################################################
  def initialize
    @services = nil
    get_list
  end

  ############################################################################
  # Returns an array of services (strings). If we've already got this array
  # before, then return the previous version. (If the caller wants to go to
  # the internet to get the array again, then they should invoke Services.new
  # again.)
  ############################################################################
  def get_list
    unless @services
      @services = Array.new
      page = WebPage.new(:services)
      doc = REXML::Document.new(page.to_s)
      doc.elements.each(ISP_WS_SERVICE_XPATH){|e| @services << e.get_text}
    end
    @services
  end
end

##############################################################################
# A class to read the ISP usage statistics and to summarise the results.
#
# A 'usage' response page looks like this:
# <internode>
#  <api>
#   <service type="Personal_ADSL" request="usage">987654321</service>
#   <traffic name="total" rollover="2012-08-16" plan-interval="Monthly" quota="10000000000" unit="bytes">4650528270</traffic>
#  </api>
# </internode>
##############################################################################
class Usage
  include IspQuotaCheckCommon

  BytesToGb = 1000000000
  SecondsPerDay = 60 * 60 * 24

  attr_reader :service, :qty_used, :next_start_date, :quota, :plan_interval, :unit_used

  ############################################################################
  # Initialise the properties of this object
  ############################################################################
  def initialize(service_text)
    @service = service_text

    @qty_used = nil
    @next_start_date = nil
    @plan_interval = nil
    @quota = nil
    @unit_used = nil
    get
  end

  ############################################################################
  # Populate properties from the remotely accessed XML document
  ############################################################################
  def get
    unless @qty_used
      page = WebPage.new(:usage, @service)
      doc = REXML::Document.new(page.to_s)
      doc.elements.each(ISP_WS_USAGE_XPATH){|e|
        @qty_used = e.get_text.to_s.to_i

        e.attributes.each{|attr,val|
          case attr
          when 'rollover'; @next_start_date = val
          when 'plan-interval'; @plan_interval = val
          when 'quota';    @quota = val.to_i
          when 'unit';     @unit_used = val
          end
        }
      }
    end
    unless @qty_used && @next_start_date && @plan_interval && @quota && @unit_used
      STDERR.puts to_s_debug("Some XML elements were not populated.")
      exit 1
    end
    unless @plan_interval=="Monthly" && @unit_used=="bytes"
      STDERR.puts to_s_debug("Either @plan_interval or @unit_used contained unexpected values.")
      exit 1
    end
    self
  end

  ############################################################################
  # Returns quota in GB. Assumes @unit_used='bytes'
  ############################################################################
  def quota_gb
    @quota.to_f / BytesToGb
  end

  ############################################################################
  # Returns GB remaining. Assumes @unit_used='bytes'
  ############################################################################
  def qty_remaining_gb
    (@quota - @qty_used).to_f / BytesToGb
  end

  ############################################################################
  # Returns (GB remain / GB quota) * 100%
  ############################################################################
  def qty_remaining_pct
    100 * qty_remaining_gb / quota_gb
  end

  ############################################################################
  # Returns days remaining until next rollover period
  ############################################################################
  def days_remaining
    date_parts = @next_start_date.split('-')
    t_next = Time.new(date_parts[0], date_parts[1], date_parts[2])
    (t_next - Time.now).to_f / SecondsPerDay
  end

  ############################################################################
  # Returns percentage of days remaining (in this month).
  # Assumes @plan_interval="Monthly"
  ############################################################################
  def days_remaining_pct
    100 * days_remaining / days_this_month
  end

  ############################################################################
  # Returns the number of days in the current month
  ############################################################################
  def days_this_month
    date_parts = @next_start_date.split('-')
    t_next = Time.new(date_parts[0], date_parts[1], date_parts[2])
    t_prev = (t_next.to_date << 1).to_time
    (t_next - t_prev).to_f / SecondsPerDay
  end

  ############################################################################
  # Return a string summary of the usage (with a timestamp)
  ############################################################################
  def to_s
    sprintf "%s %6.3f GB (%4.1f%%) and %4.1f days (%4.1f%%) left on %2d GB plan\n",
      Time.now.strftime('%F %T'), qty_remaining_gb, qty_remaining_pct,
      days_remaining, days_remaining_pct, quota_gb
  end

  ############################################################################
  # Object properties (without any info derived from those properties)
  ############################################################################
  def to_s_debug(msg='')
    msg += "\n" unless msg.length == 0 || msg.match(/\n$/)
    "#{Time.now.strftime('%F %T')} #{msg}  For service:'#{@service}':\n" +
    "  qty_used:'#{@qty_used}' quota:'#{@quota}' unit_used:'#{@unit_used}'" +
    " next_start_date:'#{@next_start_date}' plan_interval:'#{@plan_interval}'"
  end

  ############################################################################
  # Even more object properties
  ############################################################################
  def to_s_debug_more(msg='')
    "#{to_s_debug(msg)}\n" +
    "  quota[GB]:'#{quota_gb}' remain[GB]:'#{qty_remaining_gb}' remain[%]:'#{qty_remaining_pct}'\n" +
    "  remaining[days]:'#{days_remaining}' this_month[days]:'#{days_this_month}' days_remaining[%]:'#{days_remaining_pct}'"
  end

  ############################################################################
  # Show an optional message (given by the argument), then the usage
  # info, then exit the program
  ############################################################################
  def self.usage_exit(message=nil)
    STDERR.puts "#{message}\n" if message
    app = File.basename($0)

    STDERR.puts <<-MSG_COMMAND_LINE_ARGS.gsub(/^\t*/, '')
	Usage:
	  #{app}  --help|-h
	  #{app}  --setup|-s
	  #{app}

	Run with the --setup (or -s) option initially to configure your ISP username
	and password.

	Also configure constants in module IspQuotaCheckCommon for your ISP:
	- ISP_WS_BASE_URI
	- ISP_WS_SERVICE_XPATH
	- ISP_WS_USAGE_XPATH

	Then you can obtain ISP usage information by running #{app}
	(without any options).
    MSG_COMMAND_LINE_ARGS
    exit 1
  end

  ############################################################################
  # main()
  ############################################################################
  def self.main
    if ARGV.length > 0
      if %w{--setup -s}.include?(ARGV[0])
        IspConnect.ui_get_and_store_details
      elsif %w{--help -h}.include?(ARGV[0])
        usage_exit
      end
    end

    Services.new.get_list.each{|service| puts Usage.new(service)}
  end
end

##############################################################################
# Main
##############################################################################
Usage.main
exit 0

