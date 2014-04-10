#!/bin/env ruby

require 'time'

module Ps
  class List
    include Enumerable

    def initialize
      @list = %x{ps --no-headers -elf}.each_line.map do |line|
        Entry.new(line)
      end
    end

    def ancestor_pids(pid)
      ancestors = [pid]
      until pid == 1
        pid = find{|ps| ps.pid == pid}.ppid
        ancestors << pid
      end
      return ancestors
    end

    def each
      @list.each do |it|
        yield it
      end
    end
  end

  class Entry
    attr_reader :state, :user, :pid, :ppid, :priority, :nice, :cmd
    def initialize(line)
      @f, @state, @user, @pid, @ppid, @c, @priority, @nice, @addr, @size, @wchan, @stime, @tty, @time, *@cmd = *line.split
      @f = @f.to_i
      @cmd = @cmd.join(" ")
      @pid = @pid.to_i
      @ppid = @ppid.to_i
      @priority = @priority.to_i
      @nice = @nice.to_i
      @size = @size.to_i
    end
  end
end

module Tmux
  def self.run(command)
    Commands.instance.run(command)
  end

  class Commands
    def initialize
      @exe = %x(which tmux).chomp
      @env = ENV["TMUX"]
    end

    def self.instance
      @instance ||= self.new
    end

    #def target_session

    def filter_commands(command)
      case command
      when "server-info", "info"
        true
      else
        false
      end
    end

    def run(command)
      cmd = "#@exe #{command}"
      raise "Not in a tmux" unless filter_commands(command) || @env
      %x(#{cmd})
    end
  end

  class CurrentPane
    attr_reader :session, :window, :pane
    def initialize
      @session, @window, @pane = Tmux.run("display -p '#S #I #P'").split(" ").map{|it| it.to_i}
    end
    end

  class Info
    class InfoParser
      class Section
        def self.registry
          @registry ||= {}
        end

        def self.register(name)
          Section.registry[name] = self
        end

        def self.build(name, record)
          registry[name].new(record)
        end

        def initialize(record)
          @record = record
        end

        def first_line(line)
        end

        def parse_line(line)
        end
      end

      class Clients < Section
        register "Clients"
      end

      class Sessions < Section
        register "Sessions"

        def initialize(record)
          super
          @session = nil
        end

        def parse_line(line)
          case line
          when /([ \d]{2}): (\d+): (\d+) windows \(created ([^)]+)\) \[(\d+)x(\d+)\] \[flags=(\S+)\]/
            @session = Session.new
            @session.number = $~[1].to_i
            @session.window_count = $~[3].to_i
            @session.created = Time.parse($~[4])
            @session.width = $~[5].to_i
            @session.height = $~[6].to_i
            @session.flags = $~[7]
            @record.sessions << @session
          when /([ \d]{4}): (.*) \[(\d+)x(\d+)\] \[flags=(\S+), references=(\d+), .*\]/
            @window = Window.new
            @window.number = $~[1].to_i
            @window.title = $~[2]
            @window.width = $~[3].to_i
            @window.height = $~[4].to_i
            @window.flags = $~[5]
            @window.references = $~[6].to_i
            @window.session = @session
            @session.windows << @window
          when /([ \d]{6}): (\S+) (\d+) (-?\d+) (\d+)\/(\d+), (\d+) bytes; (\S+) (\d+)\/(\d+), (\d+) bytes/
            @pane = Pane.new
            @pane.number = $~[1].to_i
            @pane.ptty = $~[2]
            @pane.pid = $~[3].to_i
            @pane.fd = $~[4].to_i
            @pane.lines = $~[5].to_i
            @pane.hsize = $~[6].to_i
            @pane.window = @window
            @window.panes << @pane
          else
            raise "Can't parse #{line.inspect} as part of Sessions"
          end
        end
      end

      class Terminals < Section
        register "Terminals"
      end

      class Jobs < Section
        register "Jobs"
      end

      def initialize(string, record)
        @string = string
        @record = record
        @section = nil
      end

      def go
        lines = @string.each_line
        lines = lines.drop_while{|line| /^protocol/ !~ line}
        @record.protocol_version = (/^protocol version is (\d*)/.match(lines.shift)[1]).to_i

        lines.each do |line|
          case line
          when /^([[:alpha:]]+):/
            @section = Section.build($1, @record)
            @section.first_line(line)
          when /^\s*$/
            @section = nil
          else
            @section.parse_line(line)
          end
        end
        self
      end
    end

    class Session
      attr_accessor :number, :window_count, :created, :width, :height, :flags
      attr_reader :windows
      def initialize
        @windows = []
      end
    end

    class Window
      attr_accessor :number, :title, :width, :height, :flags, :references, :session
      attr_accessor :panes
      def initialize
        @panes = []
      end
    end

    class Pane
      attr_accessor :number, :ptty, :pid, :fd, :lines, :hsize, :window

      def inspect
        "Pane: #@number #@ptty #@pid"
      end
    end

    def self.build
      output = Tmux.run("server-info")
      info = self.new
      InfoParser.new(output, info).go
      info
    end

    attr_accessor :protocol_version, :sessions
    def initialize
      @sessions = []
    end

    def protocol_version=(number)
      raise "Don't know protocol #{number}" unless number == 7
      @protocol_version = number
    end

    def locate_process(ancestors)
      sessions.each do |session|
        session.windows.each do |window|
          window.panes.each do |pane|
            return pane if ancestors.include?(pane.pid)
          end
        end
      end
      return nil
    end
  end
end

require 'timeout'
module Vim
  def self.command(cmd)
    Commands.instance.run(cmd)
  end

  class Commands
    def self.instance
      @instance ||= self.new
    end

    def initialize
      @exe = %x{which vim}.chomp
    end

    def run(command)
      command = "#@exe #{command}"
      Timeout::timeout(5) do
        %x{#{command}}
      end
    rescue Timeout::Error
      nil
    end
  end

  class Server
    def initialize(name)
      @name = name
    end
    attr_reader :name

    def expression(expr)
      server_command("--remote-expr '#{expr}'")
    end

    def send_keys(keys)
      server_command("--remote-send '#{keys}'")
    end

    def server_command(command)
      Vim.command("--servername #@name #{command}")
    end

    def pid
      @pid ||=
        begin
          get_pid = expression("getpid()") #sometimes long
          if get_pid.nil?
            nil
          else
            get_pid.to_i
          end
        end
    end

    def alive?
      !pid.nil?
    end
  end

  class ServerList
    include Enumerable

    attr_reader :servers

    def initialize(server_prefix)
      server_regexp = /^#{server_prefix||""}.*/i
      @servers = Vim.command("--serverlist").each_line.select do |server|
        server_regexp =~ server
      end.map do |server|
        Server.new(server.chomp)
      end.compact.find_all{|vim| vim.alive?}
    end

    def empty?
      @servers.empty?
    end

    def each
      @servers.each{|s| yield s }
    end
  end
end

class SessionVims
  include Enumerable

  attr_reader :session_vims

  def initialize(server_prefix)
    @server_prefix = server_prefix

    vims = Vim::ServerList.new(server_prefix)
    if vims.empty?
      vims = Vim::ServerList.new(nil)
    end
    tmux_info = Tmux::Info::build
    current_pane = Tmux::CurrentPane.new
    ps_list = Ps::List.new

    @session_vims = vims.find_all do |vim|
      ancestors = ps_list.ancestor_pids(vim.pid)
      pane = tmux_info.locate_process(ancestors)
      pane.window.session.number == current_pane.session
    end
  end

  def each
    @session_vims.each do |vim|
      yield vim
    end
  end
end

require 'thor'
class CLI < Thor
  class_option :server_prefix

  desc "list-vims", "Quick listing of the Vims in the current TMUX"
  def list_vims
    SessionVims.new(options[:server_prefix]).each do |vim|
      p vim
    end
  end

  desc "normal-all KEYS", "Send keystrokes to all vim servers running in current session"
  def normal_all(keys)
    SessionVims.new(options[:server_prefix]).each do |vim|
      vim.send_keys("<Esc>:#{keys}<CR>")
    end
  end

  desc "find-variable NAME VALUE", "Find a session-local Vim server with a global variable set to a particular value"
  def find_variable(name, value)
    vims = SessionVims.new(options[:server_prefix]).find_all do |vim|
      vim.expression("exists(\"g:#{name}\") ? g:#{name} : \"MISSING\"").chomp == value
    end
    vims = vims.map do |vim|
      vim.name
    end
    puts vims
  end

  desc "locate-vim SERVERNAME", "Return the session, window and pane for a vim server"
  method_options :pane  => :boolean
  def locate_vim(servername)
    vim = Vim::Server.new(servername)
    ancestors = Ps::List.new.ancestor_pids(vim.pid)
    pane = Tmux::Info.build.locate_process(ancestors)
    if options[:pane]
      puts "#{pane.window.session.number}:#{pane.window.number}.#{pane.number}"
    else
      puts "#{pane.window.session.number}:#{pane.window.number}"
    end
  end

  desc "locate-buffer FILENAME", "Return the server name for vims editing FILENAME"
  def locate_buffer(filename)
    vims = Vim::ServerList.new(options[:server_prefix]).find_all do |vim|
      vim.expression("bufexists(\"#{File::absolute_path(filename)}\")").chomp == "1"
    end.map do |vim|
      vim.name
    end
    puts vims
  end
end

CLI.start(ARGV)
