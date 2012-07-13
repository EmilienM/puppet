require 'puppet/application'

class Puppet::Application::Master < Puppet::Application

  should_parse_config
  run_mode :master

  option("--debug", "-d")
  option("--verbose", "-v")

  # internal option, only to be used by ext/rack/config.ru
  option("--rack")

  option("--compile host",  "-c host") do |arg|
    options[:node] = arg
  end

  option("--logdest DEST",  "-l DEST") do |arg|
    begin
      Puppet::Util::Log.newdestination(arg)
      options[:setdest] = true
    rescue => detail
      puts detail.backtrace if Puppet[:debug]
      $stderr.puts detail.to_s
    end
  end

  option("--parseonly") do
    puts "--parseonly has been removed. Please use 'puppet parser validate <manifest>'"
    exit 1
  end

  def help
    <<-HELP

puppet-master(8) -- The puppet master daemon
========

SYNOPSIS
--------
The central puppet server. Functions as a certificate authority by
default.


USAGE
-----
puppet master [-D|--daemonize|--no-daemonize] [-d|--debug] [-h|--help]
  [-l|--logdest <file>|console|syslog] [-v|--verbose] [-V|--version]
  [--compile <node-name>]


DESCRIPTION
-----------
This command starts an instance of puppet master, running as a daemon
and using Ruby's built-in Webrick webserver. Puppet master can also be
managed by other application servers; when this is the case, this
executable is not used.


OPTIONS
-------
Note that any configuration parameter that's valid in the configuration
file is also a valid long argument. For example, 'ssldir' is a valid
configuration parameter, so you can specify '--ssldir <directory>' as an
argument.

See the configuration file documentation at
http://docs.puppetlabs.com/references/stable/configuration.html for the
full list of acceptable parameters. A commented list of all
configuration options can also be generated by running puppet master
with '--genconfig'.

* --daemonize:
  Send the process into the background. This is the default.

* --no-daemonize:
  Do not send the process into the background.

* --debug:
  Enable full debugging.

* --help:
  Print this help message.

* --logdest:
  Where to send messages. Choose between syslog, the console, and a log
  file. Defaults to sending messages to syslog, or the console if
  debugging or verbosity is enabled.

* --verbose:
  Enable verbosity.

* --version:
  Print the puppet version number and exit.

* --compile:
  Compile a catalogue and output it in JSON from the puppet master. Uses
  facts contained in the $vardir/yaml/ directory to compile the catalog.


EXAMPLE
-------
  puppet master

DIAGNOSTICS
-----------

When running as a standalone daemon, puppet master accepts the
following signals:

* SIGHUP:
  Restart the puppet master server.
* SIGINT and SIGTERM:
  Shut down the puppet master server.
* SIGUSR2:
  Close file descriptors for log files and reopen them. Used with logrotate.

AUTHOR
------
Luke Kanies


COPYRIGHT
---------
Copyright (c) 2011 Puppet Labs, LLC Licensed under the Apache 2.0 License

    HELP
  end

  def preinit
    Signal.trap(:INT) do
      $stderr.puts "Cancelling startup"
      exit(0)
    end

    # Create this first-off, so we have ARGV
    require 'puppet/daemon'
    @daemon = Puppet::Daemon.new
    @daemon.argv = ARGV.dup
  end

  def run_command
    if options[:node]
      compile
    else
      main
    end
  end

  def compile
    Puppet::Util::Log.newdestination :console
    raise ArgumentError, "Cannot render compiled catalogs without pson support" unless Puppet.features.pson?
    begin
      unless catalog = Puppet::Resource::Catalog.indirection.find(options[:node])
        raise "Could not compile catalog for #{options[:node]}"
      end

      jj catalog.to_resource
    rescue => detail
      $stderr.puts detail
      exit(30)
    end
    exit(0)
  end

  def main
    require 'etc'

    xmlrpc_handlers = [:Status, :FileServer, :Master, :Report, :Filebucket]

    xmlrpc_handlers << :CA if Puppet[:ca]

    # Make sure we've got a localhost ssl cert
    Puppet::SSL::Host.localhost

    # And now configure our server to *only* hit the CA for data, because that's
    # all it will have write access to.
    Puppet::SSL::Host.ca_location = :only if Puppet::SSL::CertificateAuthority.ca?

    if Puppet.features.root?
      begin
        Puppet::Util.chuser
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        $stderr.puts "Could not change user to #{Puppet[:user]}: #{detail}"
        exit(39)
      end
    end

    unless options[:rack]
      require 'puppet/network/server'
      @daemon.server = Puppet::Network::Server.new(:xmlrpc_handlers => xmlrpc_handlers)
      @daemon.daemonize if Puppet[:daemonize]
    else
      require 'puppet/network/http/rack'
      @app = Puppet::Network::HTTP::Rack.new(:xmlrpc_handlers => xmlrpc_handlers, :protocols => [:rest, :xmlrpc])
    end

    Puppet.notice "Starting Puppet master version #{Puppet.version}"

    unless options[:rack]
      @daemon.start
    else
      return @app
    end
  end

  def setup_logs
    # Handle the logging settings.
    if options[:debug] or options[:verbose]
      if options[:debug]
        Puppet::Util::Log.level = :debug
      else
        Puppet::Util::Log.level = :info
      end

      unless Puppet[:daemonize] or options[:rack]
        Puppet::Util::Log.newdestination(:console)
        options[:setdest] = true
      end
    end

    Puppet::Util::Log.newdestination(:syslog) unless options[:setdest]
  end

  def setup_terminuses
    require 'puppet/file_serving/content'
    require 'puppet/file_serving/metadata'

    # Cache our nodes in yaml.  Currently not configurable.
    Puppet::Node.indirection.cache_class = :yaml

    Puppet::FileServing::Content.indirection.terminus_class = :file_server
    Puppet::FileServing::Metadata.indirection.terminus_class = :file_server

    Puppet::FileBucket::File.indirection.terminus_class = :file
  end

  def setup_ssl
    # Configure all of the SSL stuff.
    if Puppet::SSL::CertificateAuthority.ca?
      Puppet::SSL::Host.ca_location = :local
      Puppet.settings.use :ca
      Puppet::SSL::CertificateAuthority.instance
    else
      Puppet::SSL::Host.ca_location = :none
    end
  end

  def setup
    raise Puppet::Error.new("Puppet master is not supported on Microsoft Windows") if Puppet.features.microsoft_windows?

    setup_logs

    exit(Puppet.settings.print_configs ? 0 : 1) if Puppet.settings.print_configs?

    Puppet.settings.use :main, :master, :ssl, :metrics

    setup_terminuses

    setup_ssl
  end
end
