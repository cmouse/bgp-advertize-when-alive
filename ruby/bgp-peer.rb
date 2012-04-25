#!/usr/bin/ruby
# chkconfig for RedHat Linux...
#
# chkconfig: 345 99 00
# description: Controls the bgp advertising daemon
# processname: bgp-peer

# chkconfig/insserv for SUSE Linux...
### BEGIN INIT INFO
# Provides: bgp-peer
# Required-Start: $all
# Should-Start:
# X-UnitedLinux-Should-Start:
# Required-Stop:
# Default-Start: 3 5
# Default-Stop:
# Short-Description: bgp-peer
# Description: Controls the bgp advertising daemon
### END INIT INFO


require 'rubygems'
require 'bgp4r'
require 'yaml'
require 'observer'
require 'daemons'

include BGP

# Set this where your config file is
configFile = "/etc/bgp-daemon.conf"
logFile = "/var/log/bgp-daemon.log"

# WARN is good. Use DEBUG when you got problems
logLevel = Logger::WARN

# end of config

class Peer
  attr_accessor :local_ip, :remote_ip, :as, :networks, :neighbor, :targets, :afi, :last_check, :ok

  def initialize(opts)
    opts.each do |k,v| self.instance_variable_set("@#{k}", v) end

    self.neighbor = Neighbor.new(
     :version => 4,
     :my_as => self.as,
     :id => self.local_ip,
     :local_addr => self.local_ip,
     :remote_addr => self.remote_ip,
     :holdtime => 10)

    self.neighbor.capability_mbgp_ipv6_unicast if @afi.to_sym == :ipv6
    self.neighbor.capability_mbgp_ipv4_unicast if @afi.to_sym == :ipv4
    @last_check = 0
    @ok = false
  end

  def update(msg)
    Log.warn "We received a #{msg.class}"
    if msg.is_a?(Notification)
      self.cleanup
    end
  end

  def connected?
    return @neighbor.state == "Established"
  end

  def cleanup
    Log.warn "Cleaning up targets for #{@name}"
    @targets.each do |target| target[:state] = 0 end
    @ok = false
  end

  def check_targets
    Log.debug "Running check_targets"

    @last_check = Time.now
    return unless self.connected?

    @ok = true

    @targets.each do |target|
      # check & advertize
      target[:state] = 0 unless target.has_key?(:state)

      # execute system check
      system(target[:check])

      # if it returns non-zero exit value, remove advertisement
      if $? == 0
        if target[:state] == 0
          Log.warn "#{target[:name]} is now OK - advertising route(s)"
          nlris = []
          target[:prefixes].each do |prefix| nlris << { :prefix => prefix } end
          if afi == :ipv4
            update = Update.new(
              Path_attribute.new(
                Origin.new(:igp),
                Multi_exit_disc.new(target[:med].to_i),
                Local_pref.new(target[:pref].to_i),
                As_path.new(@as),
                # this is always ignored...
                Next_hop.new(target[:destination]),
                Communities.new(target[:communities]),
                Mp_reach.new(:safi => 1, :nlris => nlris, :nexthop => target[:destination])
              ))
          else
            update = Update.new(
              Path_attribute.new(
                Origin.new(:igp),
                Multi_exit_disc.new(target[:med].to_i),
                Local_pref.new(target[:pref].to_i),
                As_path.new(@as),
                # this is always ignored...
                Next_hop.new('127.0.0.1'),
                Communities.new(target[:communities]),
                Mp_reach.new(:safi => 1, :nlris => nlris, :nexthop => target[:destination])
              ))
          end
          @neighbor.send_message update
          target[:state] = 1
        end
      else
        if target[:state] == 1
          Log.warn "#{target[:name]} is no longer OK - withdrawing route(s)"
          nlris = []
          target[:prefixes].each do |prefix| nlris << { :prefix => prefix } end

          update = Update.new(
             Path_attribute.new(
                Mp_unreach.new(:safi => 1, :nlris => nlris)
             )
          )
          @neighbor.send_message update
          target[:state] = 0
        end
      end
    end
  end
end

peers = []

Daemons.run_proc(File.basename('bgp-peer'), { :dir_mode => :system }) do
  config = YAML.load_file(configFile)
  Log.create(logFile)
  Log.level=logLevel

  Log.warn "bgp-peer v0.1 (c) 2012 Aki Tuomi starting up"

  # OK! Time to work for living
  config.each do |neigh|
    next unless neigh[:enabled] == 1
    peer = Peer.new neigh
    peer.targets = neigh[:targets]
    peer.neighbor.start :auto_retry => true, :no_blocking => true
    peers << peer
  end
 
  # this is needed to co-operate with bgp4r properly.
  begin
    t = Thread.new do
      loop do
        peers.each do |peer|
          if peer.ok
             peer.cleanup unless peer.connected?
          end
          peer.check_targets if (Time.now.to_i - peer.last_check.to_i > 5)
        end
        Kernel.select nil, nil, nil, 0.2
      end
    end
    t.join
   rescue Exception
     Log.warn "Shutdown completed"
     # ignore
   end
end
